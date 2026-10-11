// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The seam between the local tier and its two engines, apart from `LocalModelStore` so
// that the `SpeechTextEvaluation` tool can run the engines without the store — which
// touches `TranscriptionHistory` and the rest of the app's state.

// MARK: - Runtime seam

/// The one thing in the local-model feature that needs a third-party framework.
///
/// Everything else here — the catalogue, the hardware read, the recommendation, the
/// download bookkeeping, the Settings UI — is Foundation only. Keeping inference behind
/// a protocol means `import WhisperKit` appears in exactly one file
/// (`LocalWhisperRuntime.swift`) and `import FluidAudio` in exactly one other
/// (`LocalParakeetRuntime.swift`), so the rest stays compilable by the test target — and
/// the second engine, when it came, was one conforming type rather than a rewrite.
protocol LocalSTTRuntime: Sendable {
    /// Fetches `variant` into `base` and returns the folder it landed in. Progress is
    /// reported 0…1 on an arbitrary thread.
    func download(variant: String, into base: URL, progress: @escaping (Double) -> Void) async throws -> URL
    /// Transcribes a file with an already-installed model folder. `language` is an
    /// ISO-639-1 code, or nil to let the model detect it.
    func transcribe(audioFileURL: URL, modelFolder: URL, language: String?) async throws -> String
    /// Loads the model ahead of the first dictation. A Core ML model's first load on a Mac
    /// includes specialising it for the hardware, which is far too slow to pay mid-paste.
    func prewarm(modelFolder: URL) async throws
}

// MARK: - Registration

/// Points the `LocalSTT` seam at the real engines. Called once from
/// `applicationDidFinishLaunching`; without it the local tier reports itself unavailable,
/// which is exactly what the test target wants.
///
/// It lives here rather than in either runtime file because it names both, and neither
/// of those may see the other's framework — and not in `LocalModelStore.swift`, which
/// the evaluation tool does not compile. The dispatch is by catalogue entry:
/// an ID that is not in the catalogue at all falls through to the unavailable provider,
/// which throws rather than returning empty text, so the audio is kept for a retry.
func registerLocalSTT() {
    LocalSTT.transcriberFactory = { modelID in
        switch localSTTModel(id: modelID)?.engine {
        case .whisperKit: WhisperKitLocalTranscriber(modelID: modelID)
        case .parakeet: ParakeetLocalTranscriber(modelID: modelID)
        case nil: UnavailableLocalTranscriber(modelID: modelID)
        }
    }
    // Both, unconditionally: Settings removed *a* model and we are not told which engine
    // it belonged to, and unloading one that was never loaded costs nothing.
    LocalSTT.releaseModel = {
        Task {
            await WhisperKitPipelineCache.shared.unload()
            await ParakeetPipelineCache.shared.unload()
        }
    }
    dlog("LocalModel", "local speech engines registered (WhisperKit, FluidAudio/Parakeet)")
}
