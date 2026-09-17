// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Speech
import AVFoundation
import os.log

private let seLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeechText",
                            category: "SpeechEngine")

/// The single stored source of truth for the engine's state. The four booleans the
/// views read are computed from it, so a state can no longer be half-updated — a stop
/// that cleared `isRecording` a line before it set `isTranscribing` could be observed
/// in between as "idle".
enum RecordingPhase: Equatable {
    case idle
    /// `AVAudioEngine.prepare()/start()` running on the background queue.
    case starting
    case recording
    /// `segmentInFlight` is true while a batch/stream segment handed over at pause is
    /// still being transcribed — that is exactly when `isTranscribing` used to be true
    /// while paused. Apple pauses never set it (the live text is handed over at once).
    case paused(segmentInFlight: Bool)
    /// A stop is waiting for the final text.
    case finishing

    var isRecording: Bool { self == .recording }
    var isPaused: Bool { if case .paused = self { return true } else { return false } }
    var isTranscribing: Bool {
        switch self {
        case .finishing, .paused(segmentInFlight: true): return true
        default: return false
        }
    }
    var isStartingEngine: Bool { self == .starting }
}

@Observable
final class SpeechEngine {
    private(set) var phase: RecordingPhase = .idle {
        didSet {
            dlog("Engine", "phase: \(oldValue) → \(phase)")
            // Same signal the old `isTranscribing` didSet fired: resume waiters only on
            // the true → false edge. `paused(true) → finishing` is deliberately not an
            // edge — the segment is still in flight and a stop is now waiting on it too.
            if oldValue.isTranscribing && !phase.isTranscribing { resumeTranscriptionWaiters() }
        }
    }
    var isRecording: Bool { phase.isRecording }
    var isPaused: Bool { phase.isPaused }
    var isTranscribing: Bool { phase.isTranscribing }
    /// True while the audio engine is being prepared on the background thread.
    /// Used by the overlay to show a "preparing" animation before the mic is live.
    var isStartingEngine: Bool { phase.isStartingEngine }

    /// Every piece of text this recording has issued, with identity and state. The
    /// sessions report cumulative `committed` / `partial` strings; the layer turns them
    /// into spans, so a surface can draw the boundary between what has settled and what
    /// is still moving instead of receiving one re-joined string.
    private(set) var spanLayer = TranscriptSpanLayer()
    /// Hands spans to a sink that cannot take text back, as they become stable. Set by
    /// the inline flow while it is delivering during the recording; the Record Window
    /// leaves it nil and reads the span layer directly.
    var onSpansCommitted: (([TranscriptSpan]) -> Void)?
    /// Which spans the sink already has — see `SpanIssuer`.
    private var spanIssuer = SpanIssuer()
    /// The finalizing pass (D12): the sink's one chance to bring what it already holds in
    /// line with the authoritative text. Called synchronously once a stop's text has
    /// landed in the span layer and *before* `.idle`, because `.idle` is what wakes
    /// `awaitTranscription()` — the stop's paste must see a ledger the pass has already
    /// updated, or it pastes over a correction it does not know happened. Never called
    /// on a cancel, which does not pass through `.finishing`.
    var onFinalize: ((FinalizeInput) -> Void)?

    struct FinalizeInput {
        /// The whole recording's text, every segment — not `finalText`, which a device
        /// restart leaves holding only the last segment. Correcting the delivered text to
        /// that would delete everything said before the restart.
        let text: String
        /// The user edited some of this recording's text by hand.
        let hasFrozenSpans: Bool
        /// The History entry the stop wrote, for `correctionApplied`.
        let recordID: UUID?
    }

    /// The current segment's text, settled and moving joined — what it has always been.
    /// Computed from the span layer now, so there is one source of truth; `@Observable`
    /// tracks it through `spanLayer`.
    var liveText: String { spanLayer.segmentText }
    var finalText = "" {
        didSet {
            if oldValue != finalText {
                dlog("Engine", "finalText updated (\(finalText.count) chars): \"\(finalText.prefix(80))\"")
            }
        }
    }
    var editedText: String = ""
    /// Set when a segment's transcription is ready to be inserted at cursor
    var pendingInsertionText: String?
    /// The spans that text is made of, when it can be attributed to them — a sink that
    /// records ranges (the Record Window's `TextInsertionHandler`) keys its insertions by
    /// these, so a later pass can find and replace exactly one span. Empty when the text
    /// cannot be attributed (an Apple pause hands back its own joined string, whose
    /// partial the layer has not committed yet); the sink then inserts one untracked piece.
    private(set) var pendingInsertionSpans: [TranscriptSpanID] = []
    var errorMessage: String? {
        didSet {
            if let msg = errorMessage { dlog("Engine", "⚠ errorMessage: \(msg)") }
        }
    }
    /// Callers parked in `awaitTranscription()`. Resumed from `phase`'s didSet — the
    /// `isTranscribing` true → false edge — so there is exactly one place the signal
    /// fires, and it fires after every path has already written its
    /// `finalText` / `errorMessage` / `lastRecordID`.
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    var barLevels: [CGFloat] = Array(repeating: 0, count: 12)
    /// The latest per-segment levels from the audio thread, and whether a main-queue hop
    /// to fold them into `barLevels` is already scheduled — see `installAudioTap`.
    private let levelBox = LevelBox()
    private let levelHopPending = AtomicFlag()

    /// Kept alive between sessions so the speech model stays loaded (~300-500ms to
    /// create); rebuilt only when the locale changes.
    private var speechRecognizer: SFSpeechRecognizer?
    /// Created fresh for each recording session so it always binds to the current audio device.
    private var audioEngine: AVAudioEngine?
    /// Collects every segment's audio, whatever the tier: the batch upload, the stream's
    /// fallback, and the archive History keeps when nothing was recognised.
    private var audioBufferWriter: AudioBufferWriter?
    /// The recogniser for the current segment. One per segment: a resume makes a new one.
    private var session: RecognitionSession?
    private var transcriptionTask: Task<Void, Never>?
    /// Provider, model, keys and locale for the current/last session, read from
    /// UserDefaults once at `startRecording` so a Settings change mid-recording cannot
    /// switch the provider between pause and stop. Also kept for restart after a device change.
    private var configuration: RecordingConfiguration?
    private var providerType: STTProviderType { configuration?.provider ?? .apple }
    private var configChangeObserver: NSObjectProtocol?
    /// Incremented each time the engine is torn down. Background engine-start closures compare
    /// against this to detect stale sessions and bail out safely.
    private var engineStartToken = 0
    /// `prepare()`/`start()` run here, and so does the `stop()` of an engine that may
    /// still be starting: `AVAudioEngine` is not thread-safe, and a cancel that stopped
    /// it on main while the start was mid-flight raced two mutations of one graph.
    private let engineQueue = DispatchQueue(label: "SpeechEngine.audio", qos: .userInitiated)
    /// True once a pause has started `finish()` on the current segment, so a subsequent
    /// stop knows not to send the same audio a second time.
    private var segmentFinishStarted = false
    /// History entry written for the most recent successful transcription, so the LLM
    /// pass (which runs later, in AppState or the Record Window) can attach itself to it.
    private(set) var lastRecordID: UUID?

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// A start failed before any audio was taken — the session could not open, or the
    /// audio engine would not start. Called with the message, before the phase goes
    /// `.idle`, so the inline flow can take its overlay down: nothing else reads
    /// `errorMessage` until a stop, and there is no stop coming.
    var onStartFailure: ((String) -> Void)?

    func startRecording(locale: String = "en-US") {
        guard case .idle = phase else {
            // A second start while one is starting rebuilt the session under it; one
            // while a stop is finishing cancelled that stop's result. Both are ignored —
            // the callers cancel or wait explicitly.
            dlog("Engine", "startRecording: phase=\(phase), ignoring")
            return
        }
        configuration = .current(locale: locale)
        dlog("Engine", "startRecording: locale=\(locale), provider=\(providerType.rawValue)")
        editedText = ""
        pendingInsertionText = nil
        pendingInsertionSpans = []
        spanIssuer.reset()
        lastRecordID = nil
        spanLayer.reset()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession()
    }

    func pauseRecording() {
        dlog("Engine", "pauseRecording: phase=\(phase), provider=\(providerType.rawValue)")
        guard isRecording, let audioEngine, let session, let configuration else {
            dlog("Engine", "pauseRecording: guard failed (phase=\(phase), audioEngine=\(self.audioEngine != nil), session=\(self.session != nil))")
            return
        }
        engineQueue.sync {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        barLevels = Array(repeating: 0, count: 12)

        if let segmentText = session.pause().map(configuration.cleaned) {
            // The session already has the text (Apple): hand it over, no transcribing state.
            dlog("Engine", "pauseRecording(apple): segmentText=\(segmentText.count) chars")
            phase = .paused(segmentInFlight: false)
            if !segmentText.isEmpty {
                setPendingInsertion(segmentText)
            }
            return
        }

        phase = .paused(segmentInFlight: true)
        // This segment's audio is being sent now. Stopping without resuming must not
        // send it a second time — that produced duplicate requests (and duplicate
        // history entries, and duplicate billing) for one recording.
        segmentFinishStarted = true
        let writer = audioBufferWriter
        let locale = configuration.historyLocale
        dlog("Engine", "pauseRecording(\(configuration.streams ? "stream" : "batch")): starting transcription task")

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            var finished = await session.finish()
            finished.text = configuration.cleaned(finished.text)
            let outcome = finished
            // A resume can cancel this task while the upload is still in flight. The
            // segment was still transcribed, so it is still written to History (that is
            // not "a newer session's state", and dropping it silently lost a completed
            // upload whenever a resume raced the reply) — but nothing that belongs to
            // the session now running is touched.
            let superseded = Task.isCancelled
            await MainActor.run {
                self.recordOutcome(outcome, writer: writer, locale: locale,
                                   superseded: superseded)
                guard !superseded else { return }
                if outcome.error == nil {
                    self.spanLayer.commitSegment(outcome.text)
                    self.spanLayer.settleSegment()
                    if !outcome.text.isEmpty {
                        self.setPendingInsertion(outcome.text)
                    }
                }
                // Still paused (a stop in the meantime moved on to .finishing and its
                // waiter owns the transition): the segment has landed.
                if case .paused(segmentInFlight: true) = self.phase {
                    self.phase = .paused(segmentInFlight: false)
                }
            }
        }
    }

    func resumeRecording(locale: String = "en-US") {
        dlog("Engine", "resumeRecording: phase=\(phase), locale=\(locale)")
        guard isPaused else { return }
        configuration?.locale = locale
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession()
    }

    /// Common setup for a new recording segment. Creates a fresh engine, buffer writer
    /// and recognition session.
    private func setupRecordingSession() {
        guard let configuration else {
            dlog("Engine", "setupRecordingSession: no configuration — startRecording was never called")
            return
        }
        let locale = configuration.locale
        dlog("Engine", "setupRecordingSession: locale=\(locale), provider=\(configuration.provider.rawValue)")
        phase = .starting
        // Fresh segment with a fresh buffer writer — nothing has been sent for it yet.
        segmentFinishStarted = false
        // A resume (or a restart after a device change) opens the next segment rather
        // than wiping the timeline: `liveText` reads the current segment, so the ghost
        // text starts empty exactly as it did when it was a stored string.
        spanLayer.beginSegment()
        finalText = ""
        errorMessage = nil
        barLevels = Array(repeating: 0, count: 12)

        session?.cancel()
        session = nil

        let engine = makeAudioEngine()

        let writer = AudioBufferWriter()
        audioBufferWriter = writer

        if configuration.provider == .apple {
            // Reuse the existing recognizer when the locale is unchanged — creating a new
            // SFSpeechRecognizer reloads the speech model (~300-500ms on first use).
            if speechRecognizer?.locale.identifier != locale {
                speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            }
        }

        let newSession = makeRecognitionSession(configuration: configuration, writer: writer,
                                                recognizer: speechRecognizer)
        // `newSession` must be weak: the closure is stored on the session itself, so a
        // strong capture is a retain cycle that leaks a session (and, for the cloud
        // tiers, its AudioBufferWriter and AVAudioConverter) per segment. While the
        // session is current the engine holds it strongly, so the identity guard still
        // sees every event that should be acted on.
        // The committed string is cumulative and changes only on a commit, while a
        // partial arrives several times a second: cleaning the whole committed text on
        // every event ran three regexes per word over the entire dictation each time.
        // Its last result is kept and reused while the input is unchanged.
        var cleanedCommitted = (raw: "", cleaned: "")
        newSession.onEvent = { [weak self, weak newSession] event in
            guard let self, let newSession, self.session === newSession else { return }
            switch event {
            case .live(let committed, let partial):
                // Cleaned here, before the text becomes a span, and not at the stop: spans
                // are pasted while the user speaks, and a stop whose text no longer extends
                // what was pasted would be read as disagreement and never delivered.
                if committed != cleanedCommitted.raw {
                    cleanedCommitted = (committed, configuration.cleaned(committed))
                }
                self.spanLayer.ingest(committed: cleanedCommitted.cleaned,
                                      partial: configuration.cleaned(partial))
                self.emitCommittedSpans()
            case .failure(let message):
                self.errorMessage = message
            }
        }
        session = newSession

        // The session opens first (a stream's TLS handshake overlaps the hardware start),
        // then the tap, then the engine.
        do {
            try newSession.start()
        } catch {
            // Same terminal shape as every other failure path: the result fields first,
            // then `.idle` (so `isStartingEngine` doesn't stay true forever and parked
            // `awaitTranscription()` callers see a finished result), then `cleanup()` —
            // which also drops the fresh AVAudioEngine, its config-change observer and
            // the half-built session that would otherwise leak until the next start.
            errorMessage = error.localizedDescription
            onStartFailure?(error.localizedDescription)
            phase = .idle
            cleanup()
            return
        }

        installAudioTap()
        startAudioEngine(engine)
    }

    /// A fresh `AVAudioEngine` bound to the *current* default input device — the old one
    /// is torn down first, which avoids stale-format crashes when the user switches
    /// devices between recordings — with the configuration-change observer on it.
    private func makeAudioEngine() -> AVAudioEngine {
        tearDownAudioEngine()
        let engine = AVAudioEngine()
        audioEngine = engine

        // Observe audio hardware changes (device plugged/unplugged, AirPods switch, etc.).
        // AVAudioEngine silently stops when this happens — we need to restart on the new device.
        removeConfigChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleAudioConfigChange()
        }
        return engine
    }

    /// `prepare()` + `start()` acquire audio hardware resources and can block the main
    /// thread for 100–300 ms, so they run on `engineQueue`. The token detects a stale
    /// start (the user stopped before the engine was ready).
    private func startAudioEngine(_ engine: AVAudioEngine) {
        engineStartToken += 1
        let token = engineStartToken

        engineQueue.async { [weak self] in
            engine.prepare()
            do {
                try engine.start()
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    guard self?.engineStartToken == token else { return }
                    seLog.error("startAudioEngine: audio engine failed to start: \(desc, privacy: .public)")
                    let message = "Audio engine failed to start: \(desc)"
                    self?.errorMessage = message
                    // Only a fresh start: a restart on a new device is already recording,
                    // and its stop will report the error the ordinary way.
                    if self?.phase == .starting { self?.onStartFailure?(message) }
                    self?.phase = .idle
                    self?.cleanup()
                }
                return
            }
            DispatchQueue.main.async {
                // Session was cancelled (stop pressed before engine finished starting).
                guard let self, self.engineStartToken == token else {
                    engine.stop()
                    return
                }
                // Already `.recording` when this is a restart on a new device.
                if self.phase != .recording { self.phase = .recording }
                seLog.info("startAudioEngine: audio engine started successfully")
            }
        }
    }

    /// The audio device changed under a live segment: only the engine and its tap are
    /// rebuilt. The writer and the session stay — the writer is re-prepared for the new
    /// hardware format and keeps appending to the same 16 kHz buffer, so the segment has
    /// no boundary at all, no upload in flight, and nothing to lose.
    private func restartAudioEngine() {
        let engine = makeAudioEngine()
        installAudioTap()
        startAudioEngine(engine)
    }

    /// Returns once `isTranscribing` is false. Returns immediately when nothing is in
    /// flight, which is what a stop that never started transcription (or a cancel) needs.
    @MainActor
    func awaitTranscription() async {
        guard isTranscribing else { return }
        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func resumeTranscriptionWaiters() {
        guard !transcriptionWaiters.isEmpty else { return }
        let waiters = transcriptionWaiters
        transcriptionWaiters.removeAll()
        // The continuations hop back onto the main actor, so the caller runs after the
        // current call (including its `cleanup()`) has returned — same as the old poll.
        waiters.forEach { $0.resume() }
    }

    /// Cancel any in-progress recording or transcription without producing a result.
    /// `errorMessage` is deliberately left alone.
    func cancelRecording() {
        dlog("Engine", "cancelRecording: phase=\(phase)")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        phase = .idle
        finalText = ""
        // The whole timeline goes: nothing from a cancelled recording is issued to
        // anyone. (Text already inserted at the cursor stays — un-inserting it into a
        // foreign app is not possible — but that is the sink's ledger, not the layer's.)
        spanLayer.reset()
        spanIssuer.reset()
        // A segment handed over at a pause and not yet consumed by the panel would
        // otherwise be inserted after the cancel.
        pendingInsertionText = nil
        pendingInsertionSpans = []
        barLevels = Array(repeating: 0, count: 12)
        cleanup()
    }

    func stopRecording() {
        dlog("Engine", "stopRecording: phase=\(phase), provider=\(providerType.rawValue)")
        switch phase {
        case .recording, .paused:
            break
        default:
            // `.starting` is deliberately still ignored (the hotkey path cancels instead).
            dlog("Engine", "stopRecording: not recording or paused, ignoring")
            return
        }
        if isRecording, let audioEngine {
            engineQueue.sync {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
        let wasPaused = isPaused

        // Stopping from a paused state where the segment was already sent: the audio is
        // in flight (or done) — finish with that result instead of transcribing it again.
        if wasPaused && segmentFinishStarted {
            dlog("Engine", "stopRecording: segment already transcribed at pause — not resending")
            finalizeAfterPausedTranscription()
            return
        }

        guard let session, let configuration else {
            dlog("Engine", "stopRecording: no session — cleaning up")
            phase = .idle
            cleanup()
            return
        }

        // Stop feeding synchronously, on the thread the Apple chunk-rotation timer fires
        // on: `finish()` only stops that timer after an async hop back to main, and a
        // 50 s rotation firing in the gap would open a fresh, never-fed request whose
        // "no speech" error the token guard would then accept as the segment's error.
        // For the other tiers `pause()` is a stateless no-op; the returned text is
        // recomputed by `finish()`.
        _ = session.pause()

        phase = .finishing
        let writer = audioBufferWriter
        let locale = configuration.historyLocale
        let tier = configuration.provider == .apple ? "apple" : (configuration.streams ? "stream" : "batch")
        dlog("Engine", "stopRecording(\(tier)): liveText=\(liveText.count) chars, starting transcription task")

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            var finished = await session.finish()
            finished.text = configuration.cleaned(finished.text)
            let outcome = finished
            await MainActor.run {
                // A stale task must never touch a newer session's state — but the
                // outcome may still own a segment file (the upload finished before the
                // cancel landed), and `recordOutcome` will never run to release it.
                guard !Task.isCancelled else {
                    if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
                    return
                }
                self.recordOutcome(outcome, writer: writer, locale: locale)
                self.finalText = outcome.text
                self.spanLayer.commitSegment(outcome.text)
                self.spanLayer.settleSegment()
                self.runFinalizePass()
                self.phase = .idle
                self.cleanup()
            }
        }
    }

    /// Completes a stop that arrived while paused, reusing the transcription the pause
    /// already started. Waits for it if it's still running so `awaitTranscription()`
    /// doesn't return before the text lands. The waiter is stored in `transcriptionTask`
    /// so a cancel in the meantime stops it from running `cleanup()` against a newer session.
    private func finalizeAfterPausedTranscription() {
        if let pending = transcriptionTask, !pending.isCancelled,
           case .paused(segmentInFlight: true) = phase {
            // `paused(true) → finishing` keeps `isTranscribing` true throughout, so no
            // waiter wakes up before the text has landed.
            phase = .finishing
            transcriptionTask = Task { [weak self] in
                // Cancelling the waiter must also cancel the segment task it waits on:
                // `pending` is no longer reachable from `transcriptionTask`, and left
                // alive its completion would run against whatever newer session the
                // engine holds by then (and the abandoned upload would still be billed).
                await withTaskCancellationHandler {
                    await pending.value
                    await MainActor.run {
                        guard let self, !Task.isCancelled else { return }
                        if self.finalText.isEmpty {
                            self.finalText = self.liveText
                        }
                        self.runFinalizePass()
                        self.phase = .idle
                        self.cleanup()
                    }
                } onCancel: {
                    pending.cancel()
                }
            }
        } else {
            if finalText.isEmpty {
                finalText = liveText
            }
            runFinalizePass()
            phase = .idle
            cleanup()
        }
    }

    // MARK: - Insertion

    private func runFinalizePass() {
        guard let onFinalize else { return }
        onFinalize(FinalizeInput(text: spanLayer.text,
                                 hasFrozenSpans: spanLayer.spans.contains { $0.state == .frozen },
                                 recordID: lastRecordID))
    }

    /// Offers the stable spans a sink has not seen yet, in order — `SpanIssuer` decides
    /// which, and never offers one twice.
    ///
    /// Only while recording: a stop's authoritative text goes out through the ordinary
    /// result path, and offering it here as well would deliver the segment twice.
    private func emitCommittedSpans() {
        guard isRecording, let sink = onSpansCommitted else { return }
        let ready = spanIssuer.take(from: spanLayer)
        guard !ready.isEmpty else { return }
        sink(ready)
    }

    /// Hands a finished segment to whichever sink is listening, naming the spans it is
    /// made of when they spell exactly that text. The spans are written *before* the
    /// text, because the text is what observers key on and they must see both.
    private func setPendingInsertion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if spanLayer.segmentStableText == trimmed {
            pendingInsertionSpans = spanLayer.segmentStableSpans.map(\.id)
        } else {
            pendingInsertionSpans = []
            dlog("Span", "pending insertion is not what the spans spell — inserted untracked")
        }
        pendingInsertionText = text
    }

    // MARK: - History

    /// Writes the segment's History entry from what the session returned. Non-empty text
    /// is a success even when an error was also reported (Apple: an error after some
    /// words). With nothing recognised the audio is archived — the writer has it for every
    /// tier, so on-device recognition producing nothing still leaves a cloud retry.
    /// `superseded`: the segment landed after its task was cancelled by a resume. It
    /// still belongs in History, but the engine's live state is the *new* session's, so
    /// its failure must neither be shown as the current error nor be inferred from one.
    private func recordOutcome(_ outcome: RecognitionOutcome, writer: AudioBufferWriter?,
                               locale: String, superseded: Bool = false) {
        guard !outcome.cancelled else {
            if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
            return
        }
        let provider = providerType.rawValue
        let duration = writer?.bufferedDuration ?? 0
        let history = TranscriptionHistory.shared
        // The session only knows its own errors; engine-level failures (e.g.
        // `installAudioTap`'s "No audio input device available") live in `errorMessage`.
        // Any error known when an empty segment lands makes the entry a failure, so the
        // History row stays explainable after the fact.
        let failure = outcome.error ?? (superseded ? nil : errorMessage)
        if let error = outcome.error, !superseded {
            errorMessage = error
        }
        if !outcome.text.isEmpty {
            if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
            lastRecordID = history.recordSuccess(text: outcome.text, provider: provider,
                                                 locale: locale, duration: duration)
            return
        }
        // Nothing came back — preserve the audio so it can be retried. A batch session
        // already wrote it; otherwise archive the writer's buffer now.
        let audioURL = outcome.audioFileURL ?? (try? writer?.writeAudioFile()) ?? nil
        if let error = failure {
            history.recordFailure(error: error, provider: provider, locale: locale,
                                  duration: duration, audioURL: audioURL)
        } else {
            history.recordEmpty(provider: provider, locale: locale,
                                duration: duration, audioURL: audioURL)
        }
    }

    // MARK: - Audio

    private func installAudioTap() {
        guard let audioEngine, let writer = audioBufferWriter, let session else {
            seLog.error("installAudioTap: no audio engine")
            errorMessage = "Audio engine not initialized"
            return
        }

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Validate — a 0-channel or 0-sampleRate format means no input device is available
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            seLog.error("installAudioTap: invalid hardware format (channels=\(hwFormat.channelCount), sampleRate=\(hwFormat.sampleRate))")
            errorMessage = "No audio input device available"
            return
        }

        // Pass nil for format so AVAudioEngine uses the hardware's native format.
        // This avoids "format mismatch" ObjC exceptions that Swift can't catch.
        seLog.info("installAudioTap: hwFormat=\(hwFormat.description, privacy: .public)")

        // One conversion per buffer: the writer converts to 16 kHz mono Int16 as audio
        // arrives and hands the bytes back, and the session gets those same bytes (a
        // stream sends them; Apple takes the native buffer instead). The writer and the
        // session are per-segment and the tap is removed before either is dropped, so the
        // tap holds them strongly.
        // Re-prepared on a device restart: the format may have changed, and no tap
        // exists in between (`tearDownAudioEngine` removed it synchronously).
        writer.prepare(sourceFormat: hwFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let pcm = writer.append(buffer)
            session.feed(native: buffer, pcm16: pcm)

            guard let self else { return }
            // One main-queue hop per tap buffer (~50/s) just to smooth twelve numbers is
            // avoidable: the levels go into a box the display reads on its own clock,
            // and the hop is taken only when none is already pending.
            self.levelBox.store(Self.perSegmentRMS(buffer: buffer, count: 12))
            if !self.levelHopPending.swap(true) {
                DispatchQueue.main.async {
                    self.levelHopPending.swap(false)
                    let levels = self.levelBox.take()
                    for i in 0..<min(self.barLevels.count, levels.count) {
                        self.barLevels[i] = self.barLevels[i] * 0.2 + levels[i] * 0.8
                    }
                }
            }
        }
    }

    /// Called when the audio hardware configuration changes (device switch, sample rate change, etc.).
    /// AVAudioEngine stops itself automatically — a fresh engine on the new device carries
    /// the same segment on (`restartAudioEngine`), or, where the segment cannot cross a
    /// format change, it is closed the way a pause closes it and the next one opened.
    ///
    /// This used to rebuild the whole session, which lost the segment: the old writer was
    /// replaced before its audio was ever written, and a batch session's `cancel()` is a
    /// no-op — so with Groq or a local model the first half of a dictation vanished
    /// without a History row when AirPods connected mid-sentence.
    private func handleAudioConfigChange() {
        dlog("Engine", "handleAudioConfigChange: audio device changed, phase=\(phase)")
        seLog.warning("handleAudioConfigChange: audio device changed, phase=\(String(describing: self.phase), privacy: .public)")

        switch phase {
        case .recording:
            if providerType != .apple, audioBufferWriter?.isConvertingLive == true {
                // The cloud and local tiers only ever see the writer's 16 kHz bytes, so
                // the segment carries straight on across the new device.
                restartAudioEngine()
            } else {
                // Apple's request takes the native buffers, whose format just changed
                // (and a writer already on its native fallback path can hold only one
                // format), so the segment is closed exactly as a user pause closes it and
                // the next one opens on the new device.
                pauseRecording()
                resumeRecording(locale: configuration?.locale ?? "en-US")
            }
        case .paused:
            // Stay paused: the stale engine is discarded here, and a resume builds a fresh
            // one on the new device anyway. Going idle instead left the Record Window
            // showing a pause the engine had already abandoned.
            tearDownAudioEngine()
        case .idle, .starting, .finishing:
            // Not recording — just discard the stale engine so the next session gets a fresh one.
            // A stop that is mid-wait keeps waiting inside its session.
            tearDownAudioEngine()
        }
    }

    /// Stop and discard the current audio engine so the next session creates a fresh one.
    private func tearDownAudioEngine() {
        // Bump the token so any in-flight background prepare()/start() knows it's stale.
        engineStartToken += 1
        if let engine = audioEngine {
            // Synchronously, on the start queue: this returns only once no start is in
            // flight, which is also what lets `cleanup()` drop the writer right after —
            // the tap is gone and cannot be inside `append`. The queue is idle except
            // during the 100–300 ms of a start, so the wait is normally nothing.
            engineQueue.sync {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        audioEngine = nil
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Never writes `phase`: every caller sets `.idle` immediately before calling, after
    /// its `finalText` / `errorMessage` / `lastRecordID` are in place — so the waiters
    /// that resume on that edge always see a finished result.
    private func cleanup() {
        dlog("Engine", "cleanup: phase=\(phase)")
        // speechRecognizer is intentionally kept alive between sessions so the speech
        // model stays loaded in memory, making subsequent recordings start much faster.
        //
        // The engine (and so the tap) goes first: cancel and a failed start reach here
        // with the tap still firing, and the writer's converter is only safe to drop
        // once no callback can be inside `append`.
        tearDownAudioEngine()
        audioBufferWriter?.reset()
        audioBufferWriter = nil
        session?.cancel()
        session = nil
        removeConfigChangeObserver()
    }

    /// Split the audio buffer into N segments and compute RMS for each.
    /// Each bar gets a different time-slice of the actual audio → natural asymmetry.
    private static func perSegmentRMS(buffer: AVAudioPCMBuffer, count: Int) -> [CGFloat] {
        guard let data = buffer.floatChannelData else {
            return Array(repeating: 0, count: count)
        }
        let frames = Int(buffer.frameLength)
        let samples = data[0]
        let segmentSize = frames / count
        guard segmentSize > 0 else {
            return Array(repeating: 0, count: count)
        }

        var levels = [CGFloat]()
        levels.reserveCapacity(count)
        for i in 0..<count {
            let start = i * segmentSize
            let end = min(start + segmentSize, frames)
            var sum: Float = 0
            for j in start..<end {
                sum += samples[j] * samples[j]
            }
            let rms = sqrt(sum / Float(end - start))
            levels.append(CGFloat(min(rms * 5.0, 1.0)))
        }
        return levels
    }
}

// MARK: - Audio-thread hand-off

/// The most recent levels the tap computed. Written on the audio thread, read on main;
/// a lock around twelve values is cheaper than a block allocation per buffer.
private final class LevelBox {
    private var levels: [CGFloat] = []
    private let lock = NSLock()

    func store(_ new: [CGFloat]) {
        lock.lock(); levels = new; lock.unlock()
    }

    func take() -> [CGFloat] {
        lock.lock(); defer { lock.unlock() }
        return levels
    }
}

/// A boolean that can be set-and-read atomically from two threads.
private final class AtomicFlag {
    private var value = false
    private let lock = NSLock()

    /// Sets the flag and returns what it was.
    @discardableResult
    func swap(_ new: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
