import Foundation
import Speech
import AVFoundation
import os.log

private let seLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoicePeter",
                            category: "SpeechEngine")

@Observable
final class SpeechEngine {
    var isRecording = false
    var isPaused = false
    var liveText = ""
    var finalText = ""
    var editedText: String = ""
    /// Set when a segment's transcription is ready to be inserted at cursor
    var pendingInsertionText: String?
    var errorMessage: String?
    var isTranscribing = false
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
        guard !isRecording else { return }
        seLog.info("startRecording: locale=\(locale, privacy: .public)")
        isPaused = false
        editedText = ""
        pendingInsertionText = nil
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession(locale: locale)
    }

    func pauseRecording() {
        guard isRecording, let audioEngine else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isPaused = true
        isRecording = false
        barLevels = Array(repeating: 0, count: 12)

        let providerType = currentProviderType()

        if providerType == .apple {
            let segmentText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segmentText.isEmpty {
                pendingInsertionText = segmentText
            }
        } else {
            isTranscribing = true
            let bufferWriter = audioBufferWriter

            transcriptionTask?.cancel()
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let fileURL = try bufferWriter?.writeWAV() else { return }
                    defer { AudioBufferWriter.cleanup(fileURL: fileURL) }

                    let provider = self.makeBatchProvider(for: providerType)
                    let locale: String? = resolvedLocale()
                    let text = try await provider.transcribe(audioFileURL: fileURL, language: locale)

                    await MainActor.run {
                        self.liveText = text
                        let segmentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !segmentText.isEmpty {
                            self.pendingInsertionText = segmentText
                        }
                        self.isTranscribing = false
                    }
                } catch {
                    await MainActor.run {
                        if !Task.isCancelled {
                            self.errorMessage = error.localizedDescription
                        }
                        self.isTranscribing = false
                    }
                }
            }
        }
    }

    func resumeRecording(locale: String = "en-US") {
        guard isPaused else { return }
        isPaused = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession(locale: locale)
    }

    /// Common setup for a new recording segment. Creates fresh buffer and recognizer.
    private func setupRecordingSession(locale: String) {
        isStartingEngine = true
        currentLocale = locale
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
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                errorMessage = "Speech recognizer not available for \(locale)"
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                errorMessage = "Failed to create recognition request"
                return
            }

            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = true

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    DispatchQueue.main.async {
                        self.liveText = result.bestTranscription.formattedString
                        if result.isFinal {
                            self.finalText = result.bestTranscription.formattedString
                        }
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        if self.finalText.isEmpty {
                            self.finalText = self.liveText
                        }
                        if (error as NSError).code != 216 {
                            self.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
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

    func stopRecording() {
        guard isRecording || isPaused else { return }
        if isRecording {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        isRecording = false
        isPaused = false

        let providerType = currentProviderType()

        if providerType == .apple {
            isTranscribing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.finalText.isEmpty {
                    self.finalText = self.liveText
                }
                self.isTranscribing = false
                self.cleanup()
            }
        } else {
            isTranscribing = true
            let locale: String? = resolvedLocale()
            let bufferWriter = audioBufferWriter

            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let fileURL = try bufferWriter?.writeWAV() else {
                        throw AudioBufferWriter.AudioBufferWriterError.noAudio
                    }
                    defer { AudioBufferWriter.cleanup(fileURL: fileURL) }

                    let provider = self.makeBatchProvider(for: providerType)
                    let text = try await provider.transcribe(audioFileURL: fileURL, language: locale)

                    await MainActor.run {
                        self.finalText = text
                        self.liveText = text
                        self.isTranscribing = false
                    }
                } catch {
                    await MainActor.run {
                        if !Task.isCancelled {
                            self.errorMessage = error.localizedDescription
                        }
                        self.isTranscribing = false
                    }
                }
                await MainActor.run {
                    self.cleanup()
                }
            }
        }
    }

    private func currentProviderType() -> STTProviderType {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) ?? "apple"
        return STTProviderType(rawValue: raw) ?? .apple
    }

    private func makeBatchProvider(for type: STTProviderType) -> BatchSTTProvider {
        switch type {
        case .groq:
            let apiKey = UserDefaults.standard.string(forKey: SettingsKeys.groqAPIKey) ?? ""
            let model = UserDefaults.standard.string(forKey: SettingsKeys.groqModel) ?? "whisper-large-v3-turbo"
            return GroqSTTProvider(apiKey: apiKey, model: model)
        case .apple:
            seLog.fault("makeBatchProvider called for Apple provider — this should never happen")
            // Return Groq as fallback instead of crashing
            let apiKey = UserDefaults.standard.string(forKey: SettingsKeys.groqAPIKey) ?? ""
            let model = UserDefaults.standard.string(forKey: SettingsKeys.groqModel) ?? "whisper-large-v3-turbo"
            return GroqSTTProvider(apiKey: apiKey, model: model)
        }
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
        isStartingEngine = false
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
