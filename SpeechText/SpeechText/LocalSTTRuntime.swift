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
/// (`LocalWhisperRuntime.swift`) and `import FluidAudio` in exactly one other for the
/// engine (`LocalParakeetRuntime.swift`; the voice activity detector has its own), so the rest stays compilable by the test target — and
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
    LocalSTT.releaseModel = { modelID in
        let folder = localModelFolder(for: modelID)
        Task {
            switch localSTTModel(id: modelID)?.engine {
            case .whisperKit: await WhisperKitPipelineCache.shared.unload(ifLoaded: folder)
            case .parakeet: await ParakeetPipelineCache.shared.unload(ifLoaded: folder)
            case nil: break
            }
        }
    }
    LocalSTT.prewarm = { modelID in
        guard let model = localSTTModel(id: modelID), isLocalModelInstalled(modelID) else { return }
        let folder = localModelFolder(for: modelID)
        Task.detached(priority: .utility) {
            // The other engine's model goes first: the two caches are separate, and a
            // switch from one to the other would otherwise keep both resident.
            do {
                switch model.engine {
                case .whisperKit:
                    await ParakeetPipelineCache.shared.unload()
                    try await WhisperKitRuntime().prewarm(modelFolder: folder)
                case .parakeet:
                    await WhisperKitPipelineCache.shared.unload()
                    try await ParakeetRuntime().prewarm(modelFolder: folder)
                }
            } catch {
                dlog("LocalModel", "prewarm of \(modelID) failed: \(error.localizedDescription)")
            }
        }
    }
    dlog("LocalModel", "local speech engines registered (WhisperKit, FluidAudio/Parakeet)")
}

/// Loads the local model the settings select, if the local tier is the engine in use.
///
/// Called at launch. Core ML keeps what it compiled for the Neural Engine in
/// `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`, per macOS build and per
/// model file, and a load without it compiles again: Parakeet v3 took 28.9 s that way on
/// an M1 Pro (2026-10-16) against 0.2 s with it. A macOS update, the cache being purged
/// or the model's files being replaced all empty it — and without this, the first
/// dictation after the launch paid that wait before its paste.
func prewarmSelectedLocalModel(defaults: UserDefaults = .standard) {
    guard defaults.string(forKey: SettingsKeys.sttProvider) == STTProviderType.local.rawValue else { return }
    LocalSTT.prewarm(defaults.string(forKey: SettingsKeys.localSTTModel) ?? Provider.local.defaultSpeechModel)
}
