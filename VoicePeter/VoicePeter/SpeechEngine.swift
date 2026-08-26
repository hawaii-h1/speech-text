import Foundation
import Speech
import AVFoundation
import os.log

private let seLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoicePeter",
                            category: "SpeechEngine")

@Observable
final class SpeechEngine {
    var isRecording = false {
        didSet { dlog("Engine", "isRecording: \(oldValue) → \(isRecording)") }
    }
    var isPaused = false {
        didSet { dlog("Engine", "isPaused: \(oldValue) → \(isPaused)") }
    }
    var liveText = ""
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
    var errorMessage: String? {
        didSet {
            if let msg = errorMessage { dlog("Engine", "⚠ errorMessage: \(msg)") }
        }
    }
    var isTranscribing = false {
        didSet { dlog("Engine", "isTranscribing: \(oldValue) → \(isTranscribing)") }
    }
    var barLevels: [CGFloat] = Array(repeating: 0, count: 12)

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Created fresh for each recording session so it always binds to the current audio device.
    private var audioEngine: AVAudioEngine?
    private var audioBufferWriter: AudioBufferWriter?
    private var transcriptionTask: Task<Void, Never>?
    /// The locale used for the current/last recording session, kept for restart after device change.
    private var currentLocale: String = "en-US"
    private var configChangeObserver: NSObjectProtocol?
    /// Incremented each time the engine is torn down. Background engine-start closures compare
    /// against this to detect stale sessions and bail out safely.
    private var engineStartToken = 0
    /// True once a pause has handed the current segment's audio to a batch provider, so a
    /// subsequent stop knows not to send the same audio a second time.
    private var pausedSegmentTranscribed = false
    /// Transcript committed from earlier Apple recognition chunks (see `rotateAppleRecognition`).
    private var appleCommittedText = ""
    /// Incremented on every rotation so callbacks from retired chunks can be discarded.
    private var appleChunkToken = 0
    private var appleChunkTimer: Timer?
    /// Comfortably under SFSpeechRecognitionTask's ~60s ceiling.
    private let appleChunkDuration: TimeInterval = 50
    /// History entry written for the most recent successful transcription, so the LLM
    /// pass (which runs later, in AppState or the Record Window) can attach itself to it.
    private(set) var lastRecordID: UUID?
    /// True while the audio engine is being prepared on the background thread.
    /// Used by the overlay to show a "preparing" animation before the mic is live.
    var isStartingEngine = false

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func startRecording(locale: String = "en-US") {
        guard !isRecording else {
            dlog("Engine", "startRecording: already recording, ignoring")
            return
        }
        dlog("Engine", "startRecording: locale=\(locale), provider=\(currentProviderType().rawValue)")
        isPaused = false
        editedText = ""
        pendingInsertionText = nil
        lastRecordID = nil
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession(locale: locale)
    }

    func pauseRecording() {
        dlog("Engine", "pauseRecording: isRecording=\(isRecording), provider=\(currentProviderType().rawValue)")
        guard isRecording, let audioEngine else {
            dlog("Engine", "pauseRecording: guard failed (isRecording=\(isRecording), audioEngine=\(self.audioEngine != nil))")
            return
        }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        stopAppleChunkTimer()
        isPaused = true
        isRecording = false
        barLevels = Array(repeating: 0, count: 12)

        let providerType = currentProviderType()

        if providerType == .apple {
            let segmentText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "pauseRecording(apple): segmentText=\(segmentText.count) chars")
            if !segmentText.isEmpty {
                pendingInsertionText = segmentText
            }
        } else {
            isTranscribing = true
            let bufferWriter = audioBufferWriter
            // This segment's audio is being sent now. Stopping without resuming must not
            // send it a second time — that produced duplicate requests (and duplicate
            // history entries, and duplicate billing) for one recording.
            pausedSegmentTranscribed = true
            dlog("Engine", "pauseRecording(batch): bufferWriter=\(bufferWriter != nil), starting transcription task")

            transcriptionTask?.cancel()
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                let text = await self.transcribeBatch(providerType: providerType,
                                                      bufferWriter: bufferWriter,
                                                      locale: resolvedLocale())
                await MainActor.run {
                    if let text {
                        self.liveText = text
                        let segmentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !segmentText.isEmpty {
                            self.pendingInsertionText = segmentText
                        }
                    }
                    self.isTranscribing = false
                }
            }
        }
    }

    func resumeRecording(locale: String = "en-US") {
        dlog("Engine", "resumeRecording: isPaused=\(isPaused), locale=\(locale)")
        guard isPaused else { return }
        isPaused = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession(locale: locale)
    }

    /// Common setup for a new recording segment. Creates fresh buffer and recognizer.
    private func setupRecordingSession(locale: String) {
        dlog("Engine", "setupRecordingSession: locale=\(locale), provider=\(currentProviderType().rawValue)")
        isStartingEngine = true
        currentLocale = locale
        // Fresh segment with a fresh buffer writer — nothing has been sent for it yet.
        pausedSegmentTranscribed = false
        liveText = ""
        finalText = ""
        errorMessage = nil
        barLevels = Array(repeating: 0, count: 12)

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // Tear down the old engine entirely. Creating a fresh AVAudioEngine each session
        // guarantees it binds to the *current* default audio device, avoiding stale-format
        // crashes when the user switches input devices between recordings.
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

        audioBufferWriter = AudioBufferWriter()

        let providerType = currentProviderType()

        if providerType == .apple {
            // Reuse the existing recognizer when the locale is unchanged — creating a new
            // SFSpeechRecognizer reloads the speech model (~300-500ms on first use).
            if speechRecognizer?.locale.identifier != locale {
                speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            }
            appleCommittedText = ""
            guard startAppleRecognitionSession() else { return }
        }

        installAudioTap()

        // engine.prepare() + engine.start() acquire audio hardware resources and can block
        // the main thread for 100–300ms. Run them on a background thread so the UI stays
        // responsive. The token detects stale sessions (user stops before engine is ready).
        engineStartToken += 1
        let token = engineStartToken
        let capturedEngine = engine

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            capturedEngine.prepare()
            do {
                try capturedEngine.start()
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    guard self?.engineStartToken == token else { return }
                    seLog.error("setupRecordingSession: audio engine failed to start: \(desc, privacy: .public)")
                    self?.isStartingEngine = false
                    self?.errorMessage = "Audio engine failed to start: \(desc)"
                    self?.cleanup()
                }
                return
            }
            DispatchQueue.main.async {
                // Session was cancelled (stop pressed before engine finished starting).
                guard self?.engineStartToken == token else {
                    capturedEngine.stop()
                    return
                }
                self?.isStartingEngine = false
                self?.isRecording = true
                seLog.info("setupRecordingSession: audio engine started successfully")
            }
        }
    }

    /// Cancel any in-progress recording or transcription without producing a result.
    func cancelRecording() {
        dlog("Engine", "cancelRecording: isRecording=\(isRecording), isPaused=\(isPaused), isTranscribing=\(isTranscribing)")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        isRecording = false
        isPaused = false
        finalText = ""
        liveText = ""
        barLevels = Array(repeating: 0, count: 12)
        cleanup()
    }

    func stopRecording() {
        dlog("Engine", "stopRecording: isRecording=\(isRecording), isPaused=\(isPaused), provider=\(currentProviderType().rawValue)")
        guard isRecording || isPaused else {
            dlog("Engine", "stopRecording: not recording or paused, ignoring")
            return
        }
        if isRecording {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        let wasPaused = isPaused
        isRecording = false
        isPaused = false

        // Stopping from a paused state where the segment was already sent: the audio is
        // in flight (or done) — finish with that result instead of transcribing it again.
        if wasPaused && pausedSegmentTranscribed {
            dlog("Engine", "stopRecording: segment already transcribed at pause — not resending")
            finalizeAfterPausedTranscription()
            return
        }

        let providerType = currentProviderType()

        if providerType == .apple {
            isTranscribing = true
            let bufferWriter = audioBufferWriter
            let appleLocale = currentLocale
            dlog("Engine", "stopRecording(apple): waiting 0.5s for final result, liveText=\(liveText.count) chars")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.finalText.isEmpty {
                    dlog("Engine", "stopRecording(apple): finalText empty, using liveText (\(self.liveText.count) chars)")
                    self.finalText = self.liveText
                }
                dlog("Engine", "stopRecording(apple): done, finalText=\(self.finalText.count) chars")
                self.recordAppleOutcome(bufferWriter: bufferWriter, locale: appleLocale)
                self.isTranscribing = false
                self.cleanup()
            }
        } else {
            isTranscribing = true
            let locale: String? = resolvedLocale()
            let bufferWriter = audioBufferWriter
            dlog("Engine", "stopRecording(batch): bufferWriter=\(bufferWriter != nil), starting transcription task")

            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                let text = await self.transcribeBatch(providerType: providerType,
                                                      bufferWriter: bufferWriter,
                                                      locale: locale)
                await MainActor.run {
                    if let text {
                        self.finalText = text
                        self.liveText = text
                    }
                    self.isTranscribing = false
                    self.cleanup()
                }
            }
        }
    }

    /// Completes a stop that arrived while paused, reusing the transcription the pause
    /// already started. Waits for it if it's still running so the caller's
    /// `isTranscribing` poll doesn't finish before the text lands.
    private func finalizeAfterPausedTranscription() {
        func finish() {
            if finalText.isEmpty {
                finalText = liveText
            }
            isTranscribing = false
            cleanup()
        }

        guard let task = transcriptionTask, !task.isCancelled else {
            finish()
            return
        }

        isTranscribing = true
        Task { [weak self] in
            await task.value
            await MainActor.run {
                guard let self else { return }
                if self.finalText.isEmpty {
                    self.finalText = self.liveText
                }
                self.isTranscribing = false
                self.cleanup()
            }
        }
    }

    // MARK: - Apple Recognition Chunking

    /// SFSpeechRecognitionTask stops accepting audio after roughly a minute. Left alone,
    /// every word spoken past that point is silently dropped. We rotate to a fresh
    /// recognition task before the limit and stitch the chunks together.
    private func startAppleRecognitionSession() -> Bool {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer not available for \(currentLocale)"
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        appleChunkToken += 1
        let token = appleChunkToken

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let partial = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async {
                    // Ignore late callbacks from a chunk we've already rotated away from.
                    guard self.appleChunkToken == token else { return }
                    self.liveText = self.appleJoined(partial)
                    if isFinal {
                        dlog("Engine", "recognitionTask: isFinal=true, text=\(partial.prefix(80))")
                        self.finalText = self.liveText
                    }
                }
            }
            if let error {
                let nsErr = error as NSError
                dlog("Engine", "recognitionTask error: code=\(nsErr.code), domain=\(nsErr.domain), desc=\(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.appleChunkToken == token else { return }
                    if self.finalText.isEmpty {
                        self.finalText = self.liveText
                    }
                    if nsErr.code != 216 {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }

        scheduleAppleChunkRotation()
        return true
    }

    /// Text committed from previous chunks, joined with the in-progress chunk.
    private func appleJoined(_ partial: String) -> String {
        if appleCommittedText.isEmpty { return partial }
        if partial.isEmpty { return appleCommittedText }
        return appleCommittedText + " " + partial
    }

    private func scheduleAppleChunkRotation() {
        appleChunkTimer?.invalidate()
        appleChunkTimer = Timer.scheduledTimer(withTimeInterval: appleChunkDuration, repeats: false) { [weak self] _ in
            self?.rotateAppleRecognition()
        }
    }

    private func rotateAppleRecognition() {
        guard isRecording, currentProviderType() == .apple else { return }
        dlog("Engine", "rotateAppleRecognition: committing \(liveText.count) chars, starting fresh chunk")

        // Commit the latest partial. Partials arrive continuously, so this captures
        // essentially everything said in this chunk; at most a word at the boundary
        // is at risk, which beats losing every word after the one-minute mark.
        appleCommittedText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // The audio tap appends to `recognitionRequest` by reference, so the running
        // engine feeds the new request automatically — no need to touch the tap.
        _ = startAppleRecognitionSession()
    }

    private func stopAppleChunkTimer() {
        appleChunkTimer?.invalidate()
        appleChunkTimer = nil
    }

    /// Records the outcome of an Apple on-device session. The tap feeds the buffer writer
    /// regardless of provider, so when on-device recognition produces nothing we still have
    /// the audio and can archive it for a cloud retry instead of discarding the speech.
    private func recordAppleOutcome(bufferWriter: AudioBufferWriter?, locale: String?) {
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = bufferWriter?.bufferedDuration ?? 0
        let history = TranscriptionHistory.shared

        guard text.isEmpty else {
            lastRecordID = history.recordSuccess(text: text, provider: STTProviderType.apple.rawValue,
                                                 locale: locale, duration: duration)
            return
        }

        // Nothing came back — preserve the audio so it can be retried.
        let audioURL = try? bufferWriter?.writeWAV()
        if let error = errorMessage {
            history.recordFailure(error: error, provider: STTProviderType.apple.rawValue,
                                  locale: locale, duration: duration, audioURL: audioURL ?? nil)
        } else {
            history.recordEmpty(provider: STTProviderType.apple.rawValue, locale: locale,
                                duration: duration, audioURL: audioURL ?? nil)
        }
    }

    /// Transcribes the buffered audio with a batch provider and records the outcome in
    /// history. On failure the WAV is handed to the archive rather than deleted, so the
    /// user can retry it — a failed upload no longer means the speech is gone.
    /// Returns the transcribed text, or nil if it failed (`errorMessage` is set).
    private func transcribeBatch(providerType: STTProviderType,
                                 bufferWriter: AudioBufferWriter?,
                                 locale: String?) async -> String? {
        let duration = bufferWriter?.bufferedDuration ?? 0
        let providerName = providerType.rawValue

        let fileURL: URL
        do {
            guard let url = try bufferWriter?.writeWAV() else {
                throw AudioBufferWriter.AudioBufferWriterError.noAudio
            }
            fileURL = url
        } catch {
            dlog("Engine", "transcribeBatch: could not write WAV: \(error.localizedDescription)")
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                TranscriptionHistory.shared.recordFailure(error: error.localizedDescription,
                                                          provider: providerName, locale: locale,
                                                          duration: duration, audioURL: nil)
            }
            return nil
        }

        do {
            dlog("Engine", "transcribeBatch: calling \(providerName), locale=\(locale ?? "nil")…")
            let provider = makeBatchProvider(for: providerType)
            let text = try await provider.transcribe(audioFileURL: fileURL, language: locale)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "transcribeBatch: done, \(trimmed.count) chars")

            await MainActor.run {
                if trimmed.isEmpty {
                    // Keep the audio — an empty result is often worth a retry.
                    TranscriptionHistory.shared.recordEmpty(provider: providerName, locale: locale,
                                                            duration: duration, audioURL: fileURL)
                } else {
                    AudioBufferWriter.cleanup(fileURL: fileURL)
                    self.lastRecordID = TranscriptionHistory.shared.recordSuccess(
                        text: trimmed, provider: providerName,
                        locale: locale, duration: duration
                    )
                }
            }
            return text
        } catch {
            dlog("Engine", "transcribeBatch: error: \(error.localizedDescription)")
            let cancelled = Task.isCancelled
            await MainActor.run {
                if cancelled {
                    AudioBufferWriter.cleanup(fileURL: fileURL)
                    return
                }
                self.errorMessage = error.localizedDescription
                TranscriptionHistory.shared.recordFailure(error: error.localizedDescription,
                                                          provider: providerName, locale: locale,
                                                          duration: duration, audioURL: fileURL)
            }
            return nil
        }
    }

    private func currentProviderType() -> STTProviderType {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) ?? "apple"
        return STTProviderType(rawValue: raw) ?? .apple
    }

    private func installAudioTap() {
        guard let audioEngine else {
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            self.audioBufferWriter?.append(buffer)

            let levels = Self.perSegmentRMS(buffer: buffer, count: 12)
            DispatchQueue.main.async {
                for i in 0..<self.barLevels.count {
                    self.barLevels[i] = self.barLevels[i] * 0.2 + levels[i] * 0.8
                }
            }
        }
    }

    /// Called when the audio hardware configuration changes (device switch, sample rate change, etc.).
    /// AVAudioEngine stops itself automatically — we tear down and rebuild with a fresh engine.
    private func handleAudioConfigChange() {
        dlog("Engine", "handleAudioConfigChange: audio device changed, isRecording=\(self.isRecording), isPaused=\(self.isPaused)")
        seLog.warning("handleAudioConfigChange: audio device changed, isRecording=\(self.isRecording)")

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        guard isRecording || isPaused else {
            // Not recording — just discard the stale engine so the next session gets a fresh one.
            tearDownAudioEngine()
            return
        }

        // Restart recording on the new audio device with a fresh engine.
        let wasRecording = isRecording
        isRecording = false
        isPaused = false

        if wasRecording {
            setupRecordingSession(locale: currentLocale)
        }
    }

    /// Stop and discard the current audio engine so the next session creates a fresh one.
    private func tearDownAudioEngine() {
        // Bump the token so any in-flight background prepare()/start() knows it's stale.
        engineStartToken += 1
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func cleanup() {
        dlog("Engine", "cleanup: isTranscribing=\(isTranscribing), isRecording=\(isRecording)")
        isStartingEngine = false
        stopAppleChunkTimer()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        // speechRecognizer is intentionally kept alive between sessions so the speech
        // model stays loaded in memory, making subsequent recordings start much faster.
        audioBufferWriter?.reset()
        audioBufferWriter = nil
        tearDownAudioEngine()
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
