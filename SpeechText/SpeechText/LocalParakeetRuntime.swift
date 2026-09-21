// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import FluidAudio

/// **The only file in the app that imports FluidAudio**, as `LocalWhisperRuntime.swift`
/// is the only one that imports WhisperKit.
///
/// Parakeet TDT 0.6B v3 is NVIDIA's multilingual speech model; FluidAudio is the Swift
/// package that runs its Core ML conversion on the Neural Engine. It joined the
/// catalogue because it beat the local Whisper tier on the thing this app is for —
/// measured 2026-09-21 on an M1 Pro against a real 12.4 s Ukrainian dictation, it
/// produced the same text as ElevenLabs Scribe v2 where cloud Whisper Large v3 Turbo
/// misread the first word, in 0.34–0.61 s from a cold process, out of a 483 MB download
/// rather than Turbo's 645 MB.
///
/// Everything around it is Foundation, exactly as for WhisperKit: the catalogue, the
/// recommendation, the install bookkeeping and the Settings rows do not know this
/// framework exists. That is what keeps the standalone test bundle building, and it
/// means a third engine later is one more conforming type.
///
/// Weights: `FluidInference/parakeet-tdt-0.6b-v3-coreml`, converted from
/// `nvidia/parakeet-tdt-0.6b-v3` — CC-BY-4.0, credited in README.
struct ParakeetRuntime: LocalSTTRuntime {
    /// FluidAudio writes into `<parent of the directory you pass>/<its own folder name>`
    /// and hands back the path you gave it, so passing a folder named anything else
    /// returns a URL with nothing in it. Verified on 2026-09-21: `--model-dir /tmp/x`
    /// put the model in `/tmp/parakeet-tdt-0.6b-v3`. So the staging folder is named for
    /// the repo, and `LocalModelStore` renames it to the catalogue ID on the way in —
    /// which here are the same string, but the store's move is what guarantees it.
    func download(variant: String, into base: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let target = base.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
        return try await AsrModels.download(
            to: target,
            version: .v3,
            encoderPrecision: Self.encoderPrecision,
            progressHandler: { progress($0.fractionCompleted) }
        )
    }

    func transcribe(audioFileURL: URL, modelFolder: URL, language: String?) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        dlog("LocalParakeet", "transcribe: model=\(modelFolder.lastPathComponent), language=\(language ?? "auto")")

        let text = try await ParakeetPipelineCache.shared.transcribe(
            audioFileURL: audioFileURL, modelFolder: modelFolder, language: Self.hint(for: language)
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        dlog("LocalParakeet", "transcribe: done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }

    func prewarm(modelFolder: URL) async throws {
        try await ParakeetPipelineCache.shared.load(modelFolder)
    }

    /// The encoder build to fetch and load, and it has to be the same on both sides — the
    /// loader opens the file this names, so a download of one and a load of the other is
    /// a missing-file error. `.int8` is FluidAudio's default and is what was measured;
    /// `.int8V2` is a 577 MB rebuild that avoids a token-corruption bug (their issue
    /// #760) we have not seen, and `.int4` a 298 MB one we have not tested.
    fileprivate static let encoderPrecision: ParakeetEncoderPrecision = .int8

    /// Turns our stored language into Parakeet's hint, which on v3 filters the decoder's
    /// top-K candidates down to the language's *script*.
    ///
    /// nil on Auto — `RecordingConfiguration.cloudLanguage` already encodes "let the
    /// model decide", and v3 detects the language from the audio, which the keyboard
    /// layout cannot. Note what the hint does and does not buy: Ukrainian and Russian are
    /// both Cyrillic, so it keeps Latin letters out of a Ukrainian dictation and does
    /// nothing at all about the two being confused for each other.
    private static func hint(for language: String?) -> Language? {
        guard let language else { return nil }
        return Language(rawValue: String(language.prefix(2)).lowercased())
    }
}

/// Keeps one loaded Parakeet alive between dictations, for the reasons
/// `WhisperKitPipelineCache` does: loading is the expensive half, and Core ML specialises
/// a model for this Mac the first time it is opened.
///
/// The cost is far smaller here — the whole first run, download included, took 83 s
/// against Whisper Turbo's nine minutes of specialisation alone — but "far smaller" is
/// not "free", and a load per segment would still be paid in front of every paste.
///
/// `AsrManager` is itself an actor, so this one exists for the caching and for the
/// serialisation: an actor re-enters at every `await`, and a pause followed quickly by a
/// stop can otherwise finish two segments at once.
actor ParakeetPipelineCache {
    static let shared = ParakeetPipelineCache()

    private var folder: URL?
    private var manager: AsrManager?
    private var tail: Task<Void, Never>?

    /// Runs `job` after every job queued before it, success or failure.
    private func serialized<T>(_ job: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await job()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func load(_ modelFolder: URL) async throws {
        try await serialized { try await self.ensureLoaded(modelFolder) }
    }

    func transcribe(audioFileURL: URL, modelFolder: URL, language: Language?) async throws -> String {
        try await serialized {
            let manager = try await self.ensureLoaded(modelFolder)
            // A fresh decoder state per segment. The TDT decoder carries its prediction
            // network's state forward, which is what a *continuing* stream wants; a
            // segment here is a finished recording, and seeding it with the tail of the
            // previous one would let a stale dictation colour the next one's first words.
            var state = try TdtDecoderState(decoderLayers: AsrModelVersion.v3.decoderLayers)
            let result = try await manager.transcribe(audioFileURL, decoderState: &state, language: language)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    private func ensureLoaded(_ modelFolder: URL) async throws -> AsrManager {
        if folder == modelFolder, let manager { return manager }
        self.manager = nil
        folder = nil
        let start = CFAbsoluteTimeGetCurrent()
        // `loadLocal`, not `load`: it opens exactly the directory it is given, where
        // `load` re-derives a repo path from the parent and would not find a model in a
        // folder named after our catalogue ID. Nothing here reaches the network — a
        // dictation must never turn into a model fetch because a file went missing.
        let models = try AsrModels.loadLocal(from: modelFolder, version: .v3,
                                             encoderPrecision: ParakeetRuntime.encoderPrecision)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        folder = modelFolder
        dlog("LocalParakeet", "loaded \(modelFolder.lastPathComponent) in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s")
        return manager
    }

    /// Releases the model. Called when it is removed from disk, so the memory goes with it.
    func unload() async {
        _ = try? await serialized {
            if let manager = self.manager { await manager.cleanup() }
            self.manager = nil
            self.folder = nil
        }
    }
}

/// The batch provider the recognition tier calls. Thin, like `WhisperKitLocalProvider`:
/// it exists so `makeBatchProvider` gets the same `BatchSTTProvider` shape.
struct ParakeetLocalProvider: BatchSTTProvider {
    let modelID: String

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        guard isLocalModelInstalled(modelID) else {
            throw LocalModelError.notInstalled(localSTTModel(id: modelID)?.displayName ?? modelID)
        }
        return try await ParakeetRuntime().transcribe(
            audioFileURL: audioFileURL, modelFolder: localModelFolder(for: modelID), language: language
        )
    }
}
