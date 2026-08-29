import Foundation
import AVFoundation

// MARK: - Streaming STT Protocol

enum StreamingSTTEvent {
    /// The in-progress text of the current speech segment. Replaces the previous partial.
    case partial(String)
    /// A segment the provider considers final. Segments accumulate.
    case committed(String)
    /// The stream is no longer usable. Whatever was committed so far is still valid,
    /// but the caller should fall back to a batch upload for the whole recording.
    case failed(Error)
}

/// A provider that transcribes audio as it is being captured, over a persistent
/// connection, instead of taking a finished file. Audio is pushed as 16-bit PCM at
/// `sampleRate`; text comes back through `events` while the user is still speaking.
protocol StreamingSTTProvider: AnyObject {
    /// The sample rate `send(pcm16:)` expects. The engine converts the mic feed to it.
    var sampleRate: Double { get }
    var events: AsyncStream<StreamingSTTEvent> { get }

    /// Opens the connection. Safe to call once per instance.
    func connect(language: String?)
    /// Pushes mono 16-bit little-endian PCM. May be called from the audio thread.
    func send(pcm16: Data)
    /// Commits whatever audio is still pending, waits (bounded) for the provider's last
    /// committed segment, then closes the connection and ends `events`.
    func finish() async
    /// Drops the connection immediately without waiting for anything.
    func cancel()
}

/// Builds a streaming provider from the user's current settings, or nil when the
/// selected engine/model works in batch mode.
func makeStreamingProvider(for type: STTProviderType) -> StreamingSTTProvider? {
    let defaults = UserDefaults.standard
    switch type {
    case .elevenlabs:
        guard defaults.string(forKey: SettingsKeys.elevenLabsModel) == elevenLabsRealtimeModel else {
            return nil
        }
        return ElevenLabsRealtimeProvider(
            apiKey: defaults.string(forKey: SettingsKeys.elevenLabsAPIKey) ?? "",
            model: elevenLabsRealtimeModel
        )
    case .apple, .groq:
        return nil
    }
}

// MARK: - ElevenLabs Scribe v2 Realtime

/// WebSocket client for `wss://api.elevenlabs.io/v1/speech-to-text/realtime`.
///
/// The server runs voice-activity detection and commits a segment on every pause in
/// speech, sending `partial_transcript` while a segment is in progress and
/// `committed_transcript` when it closes. `finish()` sends a last chunk with
/// `commit: true` so the tail of the dictation is committed without waiting for the
/// VAD's silence threshold.
final class ElevenLabsRealtimeProvider: StreamingSTTProvider, @unchecked Sendable {
    let sampleRate: Double = 16_000
    let events: AsyncStream<StreamingSTTEvent>

    private let apiKey: String
    private let model: String
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pendingAudio = Data()
    private var isClosed = false
    /// Resumed by the first `committed_transcript` that arrives after `finish()` asked
    /// for a commit, so the caller does not have to guess how long to wait.
    private var finishContinuation: CheckedContinuation<Void, Never>?
    /// Set once `finish()` has asked for a commit, and flipped when that commit's
    /// transcript arrives — which can happen before the wait is even installed.
    private var awaitingCommit = false
    private var commitArrived = false

    /// Send audio in ~100 ms messages. The tap delivers ~20 ms buffers, and a WebSocket
    /// frame per buffer is mostly overhead.
    private var minimumChunkBytes: Int { Int(sampleRate) * 2 / 10 }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        var continuation: AsyncStream<StreamingSTTEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(language: String?) {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.scheme = "wss"
        var items = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
        ]
        if let language {
            items.append(URLQueryItem(name: "language_code", value: String(language.prefix(2))))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        dlog("ElevenLabs", "realtime: connecting, model=\(model), language=\(language ?? "nil")")
        let task = Self.session.webSocketTask(with: request)
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(task)
        }
    }

    func send(pcm16: Data) {
        lock.lock()
        guard !isClosed, let task else {
            lock.unlock()
            return
        }
        pendingAudio.append(pcm16)
        guard pendingAudio.count >= minimumChunkBytes else {
            lock.unlock()
            return
        }
        let chunk = pendingAudio
        pendingAudio = Data()
        lock.unlock()

        sendChunk(chunk, commit: false, over: task)
    }

    func finish() async {
        guard let (chunk, task) = takePendingForFinish() else { return }

        // The server ignores a commit with under 0.3 s of uncommitted audio
        // (`commit_throttled`), so pad the tail with 0.4 s of silence — harmless to
        // the transcript, and it guarantees the commit is honoured.
        var tail = chunk
        tail.append(Data(count: Int(sampleRate) * 2 * 4 / 10))
        dlog("ElevenLabs", "realtime: finishing, committing \(tail.count) bytes")
        sendChunk(tail, commit: true, over: task)

        // Wait for the commit's transcript, but never hang the paste on it.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.installFinishWait(cont)
                }
            }
            group.addTask { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                dlog("ElevenLabs", "realtime: no commit reply within 4s — using what we have")
                self?.resumeFinish()
            }
            // The group waits for both children on exit; the timeout resumes the
            // continuation, and the continuation's arrival cancels the timeout.
            await group.next()
            group.cancelAll()
        }

        resumeFinish()
        close(with: nil)
    }

    func cancel() {
        dlog("ElevenLabs", "realtime: cancelled")
        close(with: nil)
    }

    // MARK: Internals

    /// Locks can't be taken inside an async function, so `finish()` grabs its state here.
    private func takePendingForFinish() -> (Data, URLSessionWebSocketTask)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let task else { return nil }
        let chunk = pendingAudio
        pendingAudio = Data()
        awaitingCommit = true
        return (chunk, task)
    }

    private func sendChunk(_ pcm: Data, commit: Bool, over task: URLSessionWebSocketTask) {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "commit": commit,
            "sample_rate": Int(sampleRate),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.fail(error)
            }
        }
    }

    private func runReceiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                lock.lock()
                let closed = isClosed
                lock.unlock()
                if !closed {
                    fail(error)
                }
                return
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            handle(text)
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["message_type"] as? String else {
            dlog("ElevenLabs", "realtime: unreadable message: \(raw.prefix(120))")
            return
        }

        switch type {
        case "session_started":
            dlog("ElevenLabs", "realtime: session started")
        case "partial_transcript":
            continuation.yield(.partial(json["text"] as? String ?? ""))
        case "committed_transcript":
            let text = json["text"] as? String ?? ""
            dlog("ElevenLabs", "realtime: committed \(text.count) chars")
            continuation.yield(.committed(text))
            resumeFinish()
        case "committed_transcript_with_timestamps", "committed_transcript_entities":
            break
        case "commit_throttled":
            // Our commit was ignored (too little audio since the last one). Nothing
            // further is coming for it, so stop waiting; the stream itself is fine.
            dlog("ElevenLabs", "realtime: \(json["error"] as? String ?? "commit throttled")")
            resumeFinish()
        default:
            // Everything else the server sends is an error variant (auth_error,
            // quota_exceeded, rate_limited, session_time_limit_exceeded, …).
            let detail = json["error"] as? String ?? raw
            dlog("ElevenLabs", "realtime: \(type): \(detail.prefix(200))")
            fail(ElevenLabsError.realtime(type, detail))
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let alreadyClosed = isClosed
        lock.unlock()
        guard !alreadyClosed else { return }
        dlog("ElevenLabs", "realtime: failed: \(error.localizedDescription)")
        continuation.yield(.failed(error))
        close(with: error)
    }

    private func installFinishWait(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isClosed || commitArrived {
            lock.unlock()
            cont.resume()
            return
        }
        finishContinuation = cont
        lock.unlock()
    }

    private func resumeFinish() {
        lock.lock()
        if awaitingCommit { commitArrived = true }
        let cont = finishContinuation
        finishContinuation = nil
        lock.unlock()
        cont?.resume()
    }

    private func close(with error: Error?) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let task = self.task
        self.task = nil
        lock.unlock()

        resumeFinish()
        receiveLoop?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}

// MARK: - Live Downsampler

/// Converts the microphone's native buffers to mono 16-bit PCM at a fixed rate, one
/// buffer at a time, keeping the converter's resampling state between calls.
final class PCMDownsampler {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let ratio: Double

    init?(sourceFormat: AVAudioFormat, targetRate: Double) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            return nil
        }
        converter.downmix = true
        self.converter = converter
        self.targetFormat = target
        self.ratio = targetRate / sourceFormat.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else {
            return nil
        }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
