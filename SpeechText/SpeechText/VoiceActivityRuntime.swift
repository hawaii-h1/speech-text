// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import CoreML
import FluidAudio
import Foundation

// The voice activity detector behind `VoiceActivity` (#172): Silero VAD v6, converted to
// Core ML by FluidInference and run by FluidAudio's `VadManager` — the same package as
// the Parakeet engine, so no new dependency. The model (1 MB, MIT) ships inside the app
// rather than being downloaded, so a dictation is judged from the first one, offline
// too. App and `SpeechTextEvaluation` targets only: the test bundle cannot import
// FluidAudio, and leaves `VoiceActivity.detector` nil.

/// The bundled model's file name.
let sileroVoiceActivityModel = "silero-vad-unified-256ms-v6.2.1"

final class SileroVoiceActivityDetector: VoiceActivityDetector {
    private let manager: VadManager

    init(manager: VadManager) {
        self.manager = manager
    }

    func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        try await manager.process(samples).map(\.probability)
    }
}

/// Loads the model at `modelURL` (the app's own copy unless given one) in the
/// background and points `VoiceActivity.detector` at it; until it has loaded, and if it
/// never does, segments are let through as before. The task is returned for a caller that
/// must not start before it — the evaluation tool; the app does not wait.
@discardableResult
func registerVoiceActivity(modelURL: URL? = Bundle.main.url(forResource: sileroVoiceActivityModel,
                                                             withExtension: "mlmodelc")) -> Task<Void, Never>? {
    guard let modelURL else {
        dlog("Engine", "voice activity: the model is not in the app — every segment is sent", level: .error)
        return nil
    }
    return Task.detached(priority: .utility) {
        let start = Date()
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            VoiceActivity.detector = SileroVoiceActivityDetector(manager: VadManager(vadModel: model))
            dlog("Engine", String(format: "voice activity: Silero VAD loaded in %.0f ms",
                                  Date().timeIntervalSince(start) * 1000))
        } catch {
            dlog("Engine", "voice activity: the model would not load — every segment is sent: \(error.localizedDescription)", level: .error)
        }
    }
}
