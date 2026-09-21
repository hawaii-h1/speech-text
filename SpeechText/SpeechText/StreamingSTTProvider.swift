// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

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
    ///
    /// `languages` is the user's own list of ISO-639-1 codes, empty when they named none,
    /// and the count is the whole contract. Each provider honours as much of it as its
    /// API allows: exactly one language is forced, and a *set* reaches only the endpoint
    /// that accepts one. Everywhere else two or more means the same as none — let the
    /// model detect — because sending one of several would be a guess, and a guessed
    /// language is not a mis-spelling but a translation of what was said.
    func connect(languages: [String])
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
    switch configuration.provider {
    case .elevenlabs:
        return ElevenLabsRealtimeProvider(apiKey: configuration.elevenLabsAPIKey,
                                          model: configuration.elevenLabsModel)
    case .openai:
        return OpenAIRealtimeProvider(apiKey: configuration.openAIAPIKey,
                                      model: configuration.openAISTTModel)
    case .apple, .groq, .local:
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
    /// Serialises the socket's `send` calls, so a batch (the pre-session flush, or the
    /// messages `finish()` releases ahead of its commit) cannot be interleaved by a
    /// chunk from the audio thread. Deliberately *not* `lock`: a `send` completion that
    /// URLSession runs synchronously re-enters `fail` → `close`, which take `lock`.
    /// Always acquired before `lock`, never while holding it.
    private let sendLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pendingAudio = Data()
    /// Chunks ready to send but held until `session_started`, already encoded as the
    /// socket messages they will become, so the flush is nothing but `task.send` calls
    /// (the base64/JSON work is done on the audio thread as the chunk is buffered,
    /// which is where it would have been done anyway). Bounded by
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
    /// The text of the most recent `committed_transcript`, kept so the partial that
    /// echoes it can be recognised. Touched only from `handle`, which runs serially on
    /// the receive loop, so it needs no lock. Cleared by the first partial that says
    /// something else — that one belongs to the next segment.
    private var lastCommittedText = ""

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

    func connect(languages: [String]) {
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
        // Scribe's query string has `language_code` and nothing plural, so a set cannot
        // be narrowed here: two or more languages go unsent and the model detects.
        if languages.count == 1 {
            items.append(URLQueryItem(name: "language_code", value: languages[0]))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        dlog("ElevenLabs", "realtime: connecting, model=\(model), language=\(languages.count == 1 ? languages[0] : "auto")")
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
        // `sendLock` first, and held until the chunk is on the socket: taken only after
        // `lock` was released, a `finish()` that won it in between found `pendingAudio`
        // already emptied, committed nothing but padding, and the chunk landed *after*
        // the commit — up to 100 ms of the last word in a segment that never closes.
        sendLock.lock()
        defer { sendLock.unlock() }
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

        if let message = Self.encodeChunk(chunk, commit: false, sampleRate: sampleRate) {
            enqueue(message, over: task)
        }
    }

    /// `session_started` arrived: release everything held for it, in order, ahead of
    /// any chunk `send` produces from now on.
    private func flushPreSessionAudio() {
        // `sendLock` is taken first and held across the drain, so a chunk the audio
        // thread produces the moment `sessionStarted` flips waits behind the audio that
        // was recorded before it. `lock` is released before the sends: holding it across
        // `task.send` deadlocks the moment URLSession runs a completion synchronously,
        // because that completion path (`fail` → `close`) takes `lock` too.
        sendLock.lock()
        defer { sendLock.unlock() }

        lock.lock()
        sessionStarted = true
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        let task = self.task
        lock.unlock()

        guard let task, !held.isEmpty else { return }
        dlog("ElevenLabs", "realtime: flushing \(held.count) chunk(s) buffered before session_started")
        for message in held {
            enqueue(message, over: task)
        }
    }

    func finish() async {
        guard let (held, chunk, task) = takePendingForFinish() else { return }

        // Pad the tail with silence so the commit is not throttled — see
        // `STTTuning.streamCommitPaddingSeconds`.
        var tail = chunk
        tail.append(Data(count: bytes(forSeconds: STTTuning.streamCommitPaddingSeconds)))
        dlog("ElevenLabs", "realtime: finishing, committing \(tail.count) bytes")
        // One batch: anything still held for `session_started` has to reach the server
        // ahead of the commit, or the commit closes a segment missing its own audio.
        var messages = held
        if let commit = Self.encodeChunk(tail, commit: true, sampleRate: sampleRate) {
            messages.append(commit)
        }
        sendMessages(messages, over: task)

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

    /// Is this `partial_transcript` nothing but the segment the server already
    /// committed? Compared whole and trimmed rather than by prefix: a genuine next
    /// segment that opens with the same words is still growing, so it only matches
    /// once it has said exactly as much — and even then its own commit carries the
    /// text, so nothing is lost but a moment of ghost text.
    static func isEchoOfCommitted(partial: String, lastCommitted: String) -> Bool {
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return false }
        return partial == lastCommitted.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Puts the whole batch on the socket with nothing of another thread's in between.
    private func sendMessages(_ messages: [String], over task: URLSessionWebSocketTask) {
        sendLock.lock()
        defer { sendLock.unlock() }
        for message in messages {
            enqueue(message, over: task)
        }
    }

    /// The raw send. Callers hold `sendLock`; `task.send` only enqueues, so the hold is
    /// short even for a flush of the whole pre-session buffer.
    private func enqueue(_ text: String, over task: URLSessionWebSocketTask) {
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
            // Scribe sometimes repeats a segment it has just committed as one more
            // partial (observed ~60 ms after the commit). Taken at face value it reads
            // as a fresh segment holding the same words: the caller joins it onto the
            // committed text — pasting the dictation twice — and `partialArrivedDuringGrace`
            // makes `finish()` wait out its whole timeout for a segment that will never
            // be committed. It is an echo of a closed segment, so drop it.
            guard !Self.isEchoOfCommitted(partial: text, lastCommitted: lastCommittedText) else {
                dlog("ElevenLabs", "realtime: ignoring partial echoing the committed segment")
                return
            }
            if !text.isEmpty { lastCommittedText = "" }
            continuation.yield(.partial(text))
            if !text.isEmpty { partialArrivedDuringGrace() }
        case "committed_transcript":
            let text = json["text"] as? String ?? ""
            dlog("ElevenLabs", "realtime: committed \(text.count) chars")
            lastCommittedText = text
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

// MARK: - OpenAI GPT Live Transcribe

/// WebSocket client for `wss://api.openai.com/v1/realtime?intent=transcription`.
///
/// Three things make it a different shape from Scribe's socket, all of them established
/// against the live service on 2026-09-21 rather than read off the docs:
///
/// 1. **It runs no voice-activity detection.** `turn_detection` is rejected outright for
///    `gpt-live-transcribe` ("Turn detection is not supported for this transcription
///    model"), so nothing is ever committed on a pause: one item stays open, growing,
///    until we ask for it. There is no mid-dictation `.committed` and no VAD threshold
///    to tune — the whole segment arrives at `finish()`.
/// 2. **Transcripts arrive as increments, not restatements.** Each
///    `...transcription.delta` carries only the newly decoded text. The caller's merge
///    layer is written against cumulative strings, so the accumulation happens here and
///    `.partial` is always the whole segment so far. `.completed` carries the
///    authoritative transcript of the item and wins over the deltas that built it —
///    the deltas stopped a word short of it in every run.
/// 3. **The session must be configured before audio counts.** A fresh session has
///    `transcription: null`, so audio appended before the server acknowledges our
///    `session.update` is transcribed by nobody. `session.updated` — not the
///    `session.created` that precedes it — is therefore the "server is ready" signal
///    the pre-session buffer waits for.
///
/// The audio format is not negotiable: the session rejects any rate but exactly 24 kHz
/// (16 kHz is "below minimum", 48 kHz "above maximum"), which is why
/// `StreamingRecognitionSession` resamples for this provider instead of handing over
/// the 16 kHz bytes the upload file is made of.
final class OpenAIRealtimeProvider: StreamingSTTProvider, @unchecked Sendable {
    /// Fixed by the service — see the class comment.
    let sampleRate: Double = 24_000
    let events: AsyncStream<StreamingSTTEvent>

    private let apiKey: String
    private let model: String
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation

    private let lock = NSLock()
    /// Serialises the socket's `send` calls — same discipline as
    /// `ElevenLabsRealtimeProvider`: always acquired before `lock`, never while holding
    /// it, because a send completion URLSession runs synchronously re-enters `fail` →
    /// `close`, which take `lock`.
    private let sendLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pendingAudio = Data()
    /// Chunks encoded on the audio thread and held until `session.updated`.
    private var preSessionMessages: [String] = []
    private var preSessionBytes = 0
    private var sessionReady = false
    private var isClosed = false
    /// The languages `connect` was given, kept until `session.created` asks for the
    /// configuration. Written once before the socket opens, read on the receive loop.
    private var languages: [String] = []
    /// Resumed by the transcript of the commit `finish()` asked for.
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var awaitingCommit = false
    private var commitArrived = false
    /// Deltas accumulated per `item_id`. Touched only from `handle`, which runs serially
    /// on the receive loop, so it needs no lock.
    private var deltas: [String: String] = [:]
    /// Every item completed so far, joined. `.committed` has to be *cumulative* — that
    /// is the shape the caller's `mergedTranscript` is written against, where a commit
    /// restating everything replaces what is held. Without turn detection there is only
    /// ever one item, so this is the same string either way today; it is kept here so
    /// that a second item — if the service ever commits on a pause — appends instead of
    /// being merged against text it does not restate.
    private var completedText = ""

    /// Bytes of 16-bit mono PCM for a given duration at `sampleRate`.
    private func bytes(forSeconds seconds: Double) -> Int { Int(sampleRate * seconds) * 2 }
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

    func connect(languages: [String]) {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        dlog("OpenAI", "realtime: connecting, model=\(model), languages=\(languages.isEmpty ? "auto" : languages.joined(separator: ","))")
        let task = Self.session.webSocketTask(with: request)
        lock.lock()
        self.task = task
        self.languages = languages
        lock.unlock()
        task.resume()

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(task)
        }
    }

    func send(pcm16: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
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
        guard sessionReady else {
            // Held rather than sent: until `session.updated` the session transcribes
            // with `transcription: null`, so audio sent now is audio thrown away. If the
            // bound fills the server is not coming — fail, and let the stop upload the
            // file rather than report a transcript missing its opening seconds.
            guard preSessionBytes + chunk.count <= maxPreSessionBytes else {
                lock.unlock()
                fail(OpenAISTTError.realtime("no_session",
                    "no session.updated within \(STTTuning.streamPreSessionBufferSeconds)s of audio"))
                return
            }
            if let message = Self.encodeAudio(chunk) {
                preSessionMessages.append(message)
                preSessionBytes += chunk.count
            }
            lock.unlock()
            return
        }
        lock.unlock()

        if let message = Self.encodeAudio(chunk) {
            enqueue(message, over: task)
        }
    }

    /// `session.updated` arrived: release everything held for it, in order, ahead of any
    /// chunk `send` produces from now on.
    private func flushPreSessionAudio() {
        sendLock.lock()
        defer { sendLock.unlock() }

        lock.lock()
        guard !sessionReady else {
            lock.unlock()
            return
        }
        sessionReady = true
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        let task = self.task
        lock.unlock()

        guard let task, !held.isEmpty else { return }
        dlog("OpenAI", "realtime: flushing \(held.count) chunk(s) buffered before session.updated")
        for message in held {
            enqueue(message, over: task)
        }
    }

    func finish() async {
        guard let (held, chunk, task) = takePendingForFinish() else { return }

        // The tail is padded with silence because the server refuses a commit holding
        // under 100 ms of audio (`input_audio_buffer_commit_empty`) — and the tail of a
        // dictation is exactly where the buffer can be nearly empty. Silence costs the
        // transcript nothing; see `STTTuning.streamCommitPaddingSeconds`.
        var tail = chunk
        tail.append(Data(count: bytes(forSeconds: STTTuning.streamCommitPaddingSeconds)))
        dlog("OpenAI", "realtime: finishing, committing \(tail.count) bytes")
        var messages = held
        if let audio = Self.encodeAudio(tail) { messages.append(audio) }
        if let commit = Self.encode(["type": "input_audio_buffer.commit"]) { messages.append(commit) }
        sendMessages(messages, over: task)

        // Wait for that commit's transcript, but never hang the paste on it.
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
                dlog("OpenAI", "realtime: no transcript within \(STTTuning.streamFinishTimeoutSeconds)s — using what we have")
                self?.resumeFinish()
            }
            await group.next()
            group.cancelAll()
        }

        resumeFinish()
        close(with: nil)
    }

    func cancel() {
        dlog("OpenAI", "realtime: cancelled")
        close(with: nil)
    }

    // MARK: Internals

    /// Locks can't be taken inside an async function, so `finish()` grabs its state here.
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

    static func encodeSessionUpdate(model: String, languages: [String], sampleRate: Double) -> String? {
        var transcription: [String: Any] = ["model": model]
        switch languages.count {
        case 0:
            break
        case 1:
            // Accepted as the singular form and normalised by the server into
            // `languages: ["uk"]`, which `session.updated` echoes back.
            transcription["language"] = languages[0]
        default:
            // The one endpoint in this app that takes a *candidate set*: gpt-live-transcribe
            // picks among the languages the user says they speak instead of among all of
            // them. Every other engine here takes a single value, which is why two or more
            // languages reach them as "detect it yourself" — so this is the only place the
            // list is worth more than its first entry.
            transcription["languages"] = languages
        }
        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
            "transcription": transcription,
            // Explicitly off: a fresh session defaults to `server_vad`, which this model
            // rejects. Sending null is accepted and is what the echo confirms.
            "turn_detection": NSNull(),
        ]
        return encode(["type": "session.update",
                       "session": ["type": "transcription", "audio": ["input": input]]])
    }

    private static func encodeAudio(_ pcm: Data) -> String? {
        encode(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    private static func encode(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Puts the whole batch on the socket with nothing of another thread's in between.
    private func sendMessages(_ messages: [String], over task: URLSessionWebSocketTask) {
        sendLock.lock()
        defer { sendLock.unlock() }
        for message in messages {
            enqueue(message, over: task)
        }
    }

    private func enqueue(_ text: String, over task: URLSessionWebSocketTask) {
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
              let type = json["type"] as? String else {
            dlog("OpenAI", "realtime: unreadable message: \(raw.prefix(120))")
            return
        }

        switch type {
        case "session.created":
            // The session exists, but with `transcription: null` — it transcribes nothing
            // until it is configured. Configuring here rather than straight after
            // `resume()` costs one frame's latency (measured at about 10 ms, against the
            // 100–300 ms the microphone takes to come up) and asks nothing of
            // URLSession's queueing of sends made before the handshake finishes.
            lock.lock()
            let languages = self.languages
            let task = self.task
            lock.unlock()
            dlog("OpenAI", "realtime: session created — configuring")
            if let task, let update = Self.encodeSessionUpdate(model: model, languages: languages,
                                                              sampleRate: sampleRate) {
                sendMessages([update], over: task)
            }
        case "session.updated":
            dlog("OpenAI", "realtime: session configured (\(Self.transcriptionConfig(in: json)))")
            flushPreSessionAudio()
        case "conversation.item.input_audio_transcription.delta":
            guard let item = json["item_id"] as? String else { return }
            let accumulated = (deltas[item] ?? "") + (json["delta"] as? String ?? "")
            deltas[item] = accumulated
            // Leading whitespace: the first delta of an item opens with a space. The
            // partial carries everything completed before it for the same reason
            // `.committed` does — it is read as the whole segment so far, not as an
            // increment on it.
            let text = joinedSegments(completedText, accumulated.trimmingCharacters(in: .whitespacesAndNewlines))
            continuation.yield(.partial(text))
        case "conversation.item.input_audio_transcription.completed":
            let item = json["item_id"] as? String
            // The item's authoritative text. It has been a word or two ahead of the
            // deltas every time it was measured, so it replaces them rather than
            // extending them; the caller's `mergedTranscript` does that replacement.
            let transcript = (json["transcript"] as? String)
                ?? item.flatMap { deltas[$0] }
                ?? ""
            if let item { deltas[item] = nil }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                completedText = joinedSegments(completedText, trimmed)
            }
            dlog("OpenAI", "realtime: transcript complete, \(trimmed.count) chars")
            continuation.yield(.committed(completedText))
            resumeFinish()
        case "conversation.item.input_audio_transcription.failed":
            let detail = Self.errorDetail(in: json) ?? raw
            dlog("OpenAI", "realtime: transcription failed: \(detail.prefix(200))")
            fail(OpenAISTTError.realtime("transcription_failed", detail))
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            let code = error["code"] as? String ?? "error"
            let detail = error["message"] as? String ?? raw
            if code == "input_audio_buffer_commit_empty" {
                // The commit held too little audio to be honoured — the recording was
                // over before anything reached the socket. Nothing further is coming for
                // it, so stop waiting; the stream itself is fine and the stop falls back
                // to the upload, which has the whole segment on disk.
                dlog("OpenAI", "realtime: \(detail.prefix(160))")
                resumeFinish()
                return
            }
            dlog("OpenAI", "realtime: error \(code): \(detail.prefix(200))")
            fail(OpenAISTTError.realtime(code, detail))
        default:
            // The realtime vocabulary is large and mostly about conversations rather
            // than transcription (`input_audio_buffer.speech_started`,
            // `conversation.item.added`, …). Failing on anything unrecognised would turn
            // an informational event into a silent degrade where every recording pays
            // for the streamed minutes *and* a batch re-upload; a socket that genuinely
            // breaks still reaches `fail` through `runReceiveLoop`'s catch.
            break
        }
    }

    /// The transcription block `session.updated` echoes, for the log line — the same
    /// reason Scribe's config is printed: a typo in what we sent is visible here rather
    /// than silently ignored.
    private static func transcriptionConfig(in json: [String: Any]) -> String {
        guard let session = json["session"] as? [String: Any],
              let audio = session["audio"] as? [String: Any],
              let input = audio["input"] as? [String: Any] else { return "?" }
        let transcription = input["transcription"] as? [String: Any] ?? [:]
        let rate = (input["format"] as? [String: Any])?["rate"] ?? "?"
        let languages = transcription["languages"] ?? transcription["language"] ?? "auto"
        return "model=\(transcription["model"] ?? "?"), rate=\(rate), language=\(languages)"
    }

    private static func errorDetail(in json: [String: Any]) -> String? {
        guard let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private func fail(_ error: Error) {
        lock.lock()
        let alreadyClosed = isClosed
        lock.unlock()
        guard !alreadyClosed else { return }
        dlog("OpenAI", "realtime: failed: \(error.localizedDescription)")
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
