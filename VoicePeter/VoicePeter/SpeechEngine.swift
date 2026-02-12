import Foundation
import Speech
import AVFoundation

@Observable
final class SpeechEngine {
    var isRecording = false
    var liveText = ""
    var finalText = ""
    var errorMessage: String?
    var isTranscribing = false
    var barLevels: [CGFloat] = Array(repeating: 0, count: 12)

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var audioBufferWriter: AudioBufferWriter?
    private var transcriptionTask: Task<Void, Never>?

    var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func startRecording(locale: String = "en-US") {
        guard !isRecording else { return }

        liveText = ""
        finalText = ""
        errorMessage = nil
        isTranscribing = false
        barLevels = Array(repeating: 0, count: 12)
        transcriptionTask?.cancel()
        transcriptionTask = nil

        let providerType = currentProviderType()

        // Always set up buffer writer (needed for batch providers)
        audioBufferWriter = AudioBufferWriter()

        // Only set up Apple speech recognizer for Apple provider
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
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

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
            let locale = UserDefaults.standard.string(forKey: SettingsKeys.selectedLanguage)
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
