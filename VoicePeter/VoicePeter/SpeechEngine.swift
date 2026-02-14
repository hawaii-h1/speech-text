import Foundation
import Speech
import AVFoundation

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
    private let audioEngine = AVAudioEngine()
    private var audioBufferWriter: AudioBufferWriter?
    private var transcriptionTask: Task<Void, Never>?

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func startRecording(locale: String = "en-US") {
        guard !isRecording else { return }
        isPaused = false
        editedText = ""
        pendingInsertionText = nil
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession(locale: locale)
    }

    func pauseRecording() {
        guard isRecording else { return }
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
        liveText = ""
        finalText = ""
        errorMessage = nil
        barLevels = Array(repeating: 0, count: 12)

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        audioBufferWriter = AudioBufferWriter()

        let providerType = currentProviderType()

        if providerType == .apple {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
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

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() {
        guard isRecording || isPaused else { return }
        if isRecording {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
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
            fatalError("Apple provider does not use batch transcription")
        }
    }

    private func installAudioTap() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
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

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        audioBufferWriter?.reset()
        audioBufferWriter = nil
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
