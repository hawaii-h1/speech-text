// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One installable open-source speech model.
///
/// `id` is the WhisperKit variant name, which is also the folder name inside the
/// `argmaxinc/whisperkit-coreml` HuggingFace repo and the folder name on disk — one
/// string, so an installed model is recognised by directory listing alone and the
/// catalogue can grow without a migration.
struct LocalSTTModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    /// Measured from the HuggingFace tree API, not estimated from the variant's name:
    /// the "_632MB" suffix names the weights, while the folder also carries the mel
    /// filterbank and configs, so the real download is ~2% larger.
    let downloadBytes: Int64
    /// Below this much installed RAM the model still loads but pages, and a dictation
    /// that takes longer than it did to speak is not usable. Settings still lets the user
    /// install a heavier model — it only says so.
    let memoryFloorBytes: UInt64
    /// Shown under the model in Settings.
    let summary: String

    var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

private let gigabyte: UInt64 = 1_073_741_824

/// Every local speech model on offer, **heaviest first**. Sizes were read from the
/// HuggingFace tree API on 2026-09-16; every entry is multilingual — the `.en` builds are
/// left out because dictating Ukrainian into one produces confident nonsense.
///
/// The ladder stops at 1.6 GB, and that is not an oversight. Speech models do not scale
/// with the Mac the way chat models do: there is no larger open model with Ukrainian and a
/// Core ML runtime, so a Mac Studio with 512 GB transcribes with the same model a 32 GB
/// MacBook Air does — only faster.
let localSTTModels: [LocalSTTModel] = [
    LocalSTTModel(
        id: "openai_whisper-large-v3-v20240930",
        displayName: "Whisper Large v3",
        downloadBytes: 1_619_531_263,
        memoryFloorBytes: 24 * gigabyte,
        summary: "The full model, unquantised. In our Ukrainian and English test it made exactly the same mistakes as Turbo and answered ~30% slower."
    ),
    LocalSTTModel(
        id: "openai_whisper-large-v3-v20240930_turbo_632MB",
        displayName: "Whisper Large v3 Turbo",
        downloadBytes: 645_668_913,
        memoryFloorBytes: 8 * gigabyte,
        summary: "Near-full accuracy at a fraction of the wait. The right choice on almost every Apple Silicon Mac."
    ),
    LocalSTTModel(
        id: "openai_whisper-small_216MB",
        displayName: "Whisper Small",
        downloadBytes: 217_350_763,
        memoryFloorBytes: 4 * gigabyte,
        summary: "English only in practice: in our test it answered Ukrainian in Russian spelling and missed up to every word. Fine for English dictation."
    ),
    LocalSTTModel(
        id: "openai_whisper-base",
        displayName: "Whisper Base",
        downloadBytes: 146_719_453,
        memoryFloorBytes: 2 * gigabyte,
        summary: "English only in practice, like Small. The default on Intel Macs, which have no Neural Engine — Ukrainian speakers there are better served by a cloud engine."
    ),
    LocalSTTModel(
        id: "openai_whisper-tiny",
        displayName: "Whisper Tiny",
        downloadBytes: 76_635_397,
        memoryFloorBytes: 1 * gigabyte,
        summary: "Fast everywhere and accurate nowhere. Useful to prove the pipeline works before a real download."
    ),
]

func localSTTModel(id: String) -> LocalSTTModel? {
    localSTTModels.first { $0.id == id }
}

// MARK: - Tier picks

/// What a tier is offered: the model to install by default and the one to pick for the
/// best result the hardware allows. Each is a list of candidates, not one ID — the first
/// that clears the RAM floor and fits on disk wins — so a tier's pick degrades gracefully
/// on a Mac at the bottom of its memory range, or with a nearly full disk.
///
/// "Recommended" is the fastest model of good enough quality, not the best one: the user
/// is waiting for the paste, and latency is the thing a dictation app is judged on.
struct TierPicks {
    let recommended: [String]
    let bestQuality: [String]
}

/// The step-down floor both lists end on, so a pick always exists if anything fits.
private let sttFallback = ["openai_whisper-small_216MB", "openai_whisper-base", "openai_whisper-tiny"]

func localSTTPicks(for tier: MacTier) -> TierPicks {
    let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    switch tier {
    case .intel:
        // No Neural Engine: the large models run on the CPU, slower than speaking again.
        return TierPicks(recommended: ["openai_whisper-base", "openai_whisper-tiny"],
                         bestQuality: sttFallback)
    case .entry, .standard:
        return TierPicks(recommended: [turbo] + sttFallback, bestQuality: [turbo] + sttFallback)
    case .plus, .pro, .max, .ultra:
        // Not the full Large v3 for best quality: measured on 2026-09-17 (M1 Pro, synthesised
        // Ukrainian and English), it reproduced Turbo's errors word for word and was ~30%
        // slower. It stays in the catalogue for anyone who wants to check on their own voice.
        return TierPicks(recommended: [turbo] + sttFallback, bestQuality: [turbo] + sttFallback)
    }
}

/// The first candidate that clears its RAM floor and fits on disk with a gigabyte to
/// spare. Shared by speech and chat, which differ only in their catalogues.
func firstFitting<Model>(_ candidates: [String], in catalog: [Model],
                         id: (Model) -> String, floor: (Model) -> UInt64, bytes: (Model) -> Int64,
                         capabilities: SystemCapabilities) -> Model? {
    let usableDisk = capabilities.freeDiskBytes > gigabyte ? capabilities.freeDiskBytes - gigabyte : 0
    for candidate in candidates {
        guard let model = catalog.first(where: { id($0) == candidate }) else { continue }
        if capabilities.memoryBytes >= floor(model), usableDisk >= UInt64(bytes(model)) { return model }
    }
    return nil
}

func recommendedLocalSTTModel(for capabilities: SystemCapabilities) -> LocalSTTModel? {
    firstFitting(localSTTPicks(for: MacTier(capabilities)).recommended, in: localSTTModels,
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

func bestQualityLocalSTTModel(for capabilities: SystemCapabilities) -> LocalSTTModel? {
    firstFitting(localSTTPicks(for: MacTier(capabilities)).bestQuality, in: localSTTModels,
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

/// Whether the Mac has the memory for a model at all — Settings labels heavier ones
/// rather than hiding them, since the user may know better (a Mac that does nothing else).
func localModelFitsMemory(_ floorBytes: UInt64, _ capabilities: SystemCapabilities) -> Bool {
    capabilities.memoryBytes >= floorBytes
}

/// Why the recommendation landed where it did, in one sentence, for the Settings row.
/// A recommendation the user cannot interrogate is one they have to take on faith.
func localSTTRecommendationReason(for capabilities: SystemCapabilities) -> String {
    guard let model = recommendedLocalSTTModel(for: capabilities) else {
        return "Not enough free disk space to install any local model."
    }
    let tier = MacTier(capabilities)
    if tier == .intel {
        return "\(model.displayName) — Intel Macs have no Neural Engine, so the larger models run too slowly for dictation."
    }
    return "\(model.displayName) for a \(tier.displayName) Mac."
}

enum LocalModelError: LocalizedError {
    case notInstalled(String)
    case downloadFailed(String)
    case insufficientDisk

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "The local model \"\(name)\" is not installed yet"
        case .downloadFailed(let why): "Could not install the local model: \(why)"
        case .insufficientDisk: "Not enough free disk space to install this model"
        }
    }
}

// MARK: - Runtime registration

/// How `makeBatchProvider` reaches the local engine without naming it.
///
/// The test target compiles `STTProvider.swift`, so that file's switch has to cover
/// `.local` — but it must not drag WhisperKit in, or the standalone test bundle stops
/// building (see **Tests** in CLAUDE.md). So the app registers a real factory at launch
/// (`registerLocalSTT()` in `LocalWhisperRuntime.swift`) and everything else talks to
/// this box. Unregistered — which is exactly the test target's state — the tier reports
/// itself unavailable instead of crashing.
enum LocalSTT {
    /// Builds a batch provider for an installed model ID. Replaced at launch.
    nonisolated(unsafe) static var providerFactory: (String) -> BatchSTTProvider = {
        UnavailableLocalSTTProvider(modelID: $0)
    }

    /// Drops the loaded model from memory — `LocalModelStore.remove` calls it, so deleting
    /// a model frees its RAM too instead of leaving it resident until the next switch.
    nonisolated(unsafe) static var releaseModel: () -> Void = {}
}

// MARK: - On-disk layout

/// Where installed models live.
///
/// Inside `Application Support/SpeechText/` on purpose: `TranscriptionHistory`'s
/// `adoptPreRenameStore()` moves that whole folder across a bundle-identifier change,
/// so models survive a rename without a migration of their own.
func localModelsDirectory() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("SpeechText", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
}

func localModelFolder(for modelID: String) -> URL {
    localModelsDirectory().appendingPathComponent(modelID, isDirectory: true)
}

/// Whether a model is ready to transcribe with.
///
/// A plain directory test, and free of both WhisperKit and the main actor — which is
/// why a finished download is *moved* into our own layout rather than left in the Hub
/// cache's nested `models/<org>/<repo>/` shape. Any thread, any target, can ask.
/// The `.mlmodelc` check matters: an interrupted move leaves the folder there but empty.
func isLocalModelInstalled(_ modelID: String) -> Bool {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: localModelFolder(for: modelID).path)
    else { return false }
    return contents.contains { $0.hasSuffix(".mlmodelc") }
}

/// Stands in for the local engine when none was registered. It never silently returns
/// empty text: a dictation that produced nothing has to surface as an error so the
/// existing failure paths (status overlay, History entry with the audio kept) run.
struct UnavailableLocalSTTProvider: BatchSTTProvider {
    let modelID: String

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        throw LocalModelError.notInstalled(localSTTModel(id: modelID)?.displayName ?? modelID)
    }
}

/// The stored default before the user picks — also the normalisation fallback. Turbo,
/// not the head of the catalogue: it is what nearly every Apple Silicon Mac is recommended.
let defaultLocalSTTModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
