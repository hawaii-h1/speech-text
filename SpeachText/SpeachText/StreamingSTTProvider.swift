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

/// Builds a streaming provider for a session's configuration, or nil when the
/// selected engine/model works in batch mode.
func makeStreamingProvider(configuration: RecordingConfiguration) -> StreamingSTTProvider? {
    guard configuration.streams else { return nil }
    return ElevenLabsRealtimeProvider(apiKey: configuration.elevenLabsAPIKey,
                                      model: configuration.elevenLabsModel)
}

// MARK: - ElevenLabs Scribe v2 Realtime

/// WebSocket client for `wss://api.elevenlabs.io/v1/speech-to-text/realtime`.
///
/// The server runs voice-activity detection and commits a segment on every pause in
/// speech, sending `partial_transcript` while a segment is in progress and
/// `committed_transcript` when it closes. `finish()` sends a last chunk with
/// `commit: true` so the tail of the dictation is committed without waiting for the
/// VAD's silence threshold.
///
/// The engine calls `connect` before it starts `AVAudioEngine`, so the TLS handshake
/// overlaps the 100–300 ms the hardware takes to come up. Audio that arrives before
/// the server's `session_started` is held in `preSessionMessages` — already encoded as
/// the socket messages it will become, on the audio thread — and flushed the moment it
/// does: the server does not promise to keep audio sent ahead of that message, and
/// the first syllable of a dictation is exactly what must not be lost.
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
    /// Chunks ready to send but held until `session_started`, already encoded as the
    /// socket messages they will become, so the flush under the lock is nothing but
    /// `task.send` calls (the base64/JSON work is done on the audio thread as the chunk
    /// is buffered, which is where it would have been done anyway). Bounded by
    /// `STTTuning.streamPreSessionBufferSeconds`: if it fills, the stream fails over.
    private var preSessionMessages: [String] = []
    private var preSessionBytes = 0
    private var sessionStarted = false
    private var isClosed = false
    /// Resumed by the first `committed_transcript` that arrives after `finish()` asked
    /// for a commit, so the caller does not have to guess how long to wait.
    private var finishContinuation: CheckedContinuation<Void, Never>?
    /// Set once `finish()` has asked for a commit, and flipped when that commit's
    /// transcript arrives — which can happen before the wait is even installed.
    private var awaitingCommit = false
    private var commitArrived = false
    /// Counts down `STTTuning.streamCommitGraceSeconds` after a `committed_transcript`
    /// seen while awaiting the commit; cancelled by a partial that shows more is coming.
    private var commitGrace: Task<Void, Never>?

    /// Bytes of 16-bit mono PCM for a given duration at `sampleRate`.
    private func bytes(forSeconds seconds: Double) -> Int { Int(sampleRate * seconds) * 2 }
    /// Send audio in `STTTuning.streamChunkSeconds` messages rather than one per tap buffer.
    private var minimumChunkBytes: Int { bytes(forSeconds: STTTuning.streamChunkSeconds) }
    private var maxPreSessionBytes: Int { bytes(forSeconds: STTTuning.streamPreSessionBufferSeconds) }

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
            // Tunables and quality flags — see `STTTuning`. The server echoes both in
            // `session_started.config` (verified live), so a typo here would be visible
            // in the debug log rather than silently ignored.
            URLQueryItem(name: "vad_silence_threshold_secs",
                         value: String(STTTuning.vadSilenceThresholdSeconds)),
            URLQueryItem(name: "no_verbatim", value: STTTuning.noVerbatim ? "true" : "false"),
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
        guard sessionStarted else {
            // Handshake still in flight: hold the chunk. If the bound is hit the server
            // is not coming; rather than drop audio and later call a transcript missing
            // its opening seconds a success, fail so the stop takes the batch upload.
            guard preSessionBytes + chunk.count <= maxPreSessionBytes else {
                lock.unlock()
                fail(ElevenLabsError.realtime("no_session",
                    "no session_started within \(STTTuning.streamPreSessionBufferSeconds)s of audio"))
                return
            }
            if let message = Self.encodeChunk(chunk, commit: false, sampleRate: sampleRate) {
                preSessionMessages.append(message)
                preSessionBytes += chunk.count
            }
            lock.unlock()
            return
        }
        lock.unlock()

        sendChunk(chunk, commit: false, over: task)
    }

    /// `session_started` arrived: release everything held for it, in order, ahead of
    /// any chunk `send` produces from now on (it still holds the lock while we drain).
    private func flushPreSessionAudio() {
        lock.lock()
        sessionStarted = true
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        // Drain under the lock: `task.send` only enqueues (the messages were encoded
        // when they were buffered), and releasing first would let a chunk from the
        // audio thread overtake the audio recorded before it.
        if let task, !held.isEmpty {
            dlog("ElevenLabs", "realtime: flushing \(held.count) chunk(s) buffered before session_started")
            for message in held {
                sendMessage(message, over: task)
            }
        }
        lock.unlock()
    }

    func finish() async {
        guard let (held, chunk, task) = takePendingForFinish() else { return }
        for message in held {
            sendMessage(message, over: task)
        }

        // Pad the tail with silence so the commit is not throttled — see
        // `STTTuning.streamCommitPaddingSeconds`.
        var tail = chunk
        tail.append(Data(count: bytes(forSeconds: STTTuning.streamCommitPaddingSeconds)))
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
                try? await Task.sleep(nanoseconds: UInt64(STTTuning.streamFinishTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                dlog("ElevenLabs", "realtime: no commit reply within \(STTTuning.streamFinishTimeoutSeconds)s — using what we have")
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
    /// Returns the messages still held for `session_started` (they go out ahead of the
    /// commit; if the session never started, the commit fails and the batch path takes
    /// over), the audio to commit, and the socket.
    private func takePendingForFinish() -> ([String], Data, URLSessionWebSocketTask)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let task else { return nil }
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        let chunk = pendingAudio
        pendingAudio = Data()
        awaitingCommit = true
        return (held, chunk, task)
    }

    private static func encodeChunk(_ pcm: Data, commit: Bool, sampleRate: Double) -> String? {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "commit": commit,
            "sample_rate": Int(sampleRate),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sendChunk(_ pcm: Data, commit: Bool, over task: URLSessionWebSocketTask) {
        guard let text = Self.encodeChunk(pcm, commit: commit, sampleRate: sampleRate) else { return }
        sendMessage(text, over: task)
    }

    private func sendMessage(_ text: String, over task: URLSessionWebSocketTask) {
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
            let config = json["config"] as? [String: Any] ?? [:]
            dlog("ElevenLabs", "realtime: session started (vad_silence=\(config["vad_silence_threshold_secs"] ?? "?"), no_verbatim=\(config["no_verbatim"] ?? "?"))")
            flushPreSessionAudio()
        case "partial_transcript":
            let text = json["text"] as? String ?? ""
            continuation.yield(.partial(text))
            if !text.isEmpty { partialArrivedDuringGrace() }
        case "committed_transcript":
            let text = json["text"] as? String ?? ""
            dlog("ElevenLabs", "realtime: committed \(text.count) chars")
            continuation.yield(.committed(text))
            commitReplyArrived()
        case "committed_transcript_with_timestamps", "committed_transcript_entities":
            break
        case "commit_throttled":
            // Our commit was ignored (too little audio since the last one). Nothing
            // further is coming for it, so stop waiting; the stream itself is fine.
            dlog("ElevenLabs", "realtime: \(json["error"] as? String ?? "commit throttled")")
            resumeFinish()
        case "auth_error", "quota_exceeded", "rate_limited", "session_time_limit_exceeded",
             "error", "invalid_request":
            // The documented error variants. Only these end the stream: failing on
            // anything unrecognised would turn a future informational message (a
            // keepalive, a VAD state change, …) into a silent degrade where every
            // recording pays for the streamed minutes *and* a batch re-upload.
            let detail = json["error"] as? String ?? raw
            dlog("ElevenLabs", "realtime: \(type): \(detail.prefix(200))")
            fail(ElevenLabsError.realtime(type, detail))
        default:
            // Unknown but well-formed — the server's vocabulary is open (three purely
            // informational types are already special-cased above). A socket that
            // genuinely breaks still reaches `fail` through `runReceiveLoop`'s catch,
            // so ignoring this never loses the batch fallback.
            dlog("ElevenLabs", "realtime: ignoring unknown message_type \(type)")
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

    /// A `committed_transcript` while `finish()` is waiting. It is probably the reply
    /// to our commit — but it may be an earlier VAD segment's, with ours still queued
    /// behind it, so release the wait only after `STTTuning.streamCommitGraceSeconds`
    /// pass without a partial showing that another segment is open.
    private func commitReplyArrived() {
        lock.lock()
        guard awaitingCommit, !isClosed else {
            lock.unlock()
            return
        }
        commitGrace?.cancel()
        commitGrace = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(STTTuning.streamCommitGraceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumeFinish()
        }
        lock.unlock()
    }

    /// The server is still transcribing after that commit reply: it was not ours. Keep
    /// waiting for the next one (the `finish()` timeout still bounds the whole wait).
    private func partialArrivedDuringGrace() {
        lock.lock()
        let grace = commitGrace
        commitGrace = nil
        lock.unlock()
        if let grace {
            dlog("ElevenLabs", "realtime: partial after a commit reply — waiting for the next commit")
            grace.cancel()
        }
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
        commitGrace?.cancel()
        commitGrace = nil
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
