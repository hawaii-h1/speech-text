// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The audio corpus through the local engines (#80) — the half of a corpus run that the
/// standalone test bundle cannot do, because it may not import WhisperKit or FluidAudio.
/// The same clips, the same `LiveDictation` run and the same checks as
/// `LiveProviderTests`, written into the same run folder, so `summary.md` holds one table.
///
///     SpeechTextEvaluation --corpus <dir> [--run-dir <dir>] [--engines a,b] [--clips a,b] [--cloud]
///
/// `--cloud` adds the cloud engines, with keys from the environment only. A model that is
/// not on this Mac is a `not installed` row. `scripts/evaluate.sh` runs both halves.
@main
struct SpeechTextEvaluation {
    @MainActor
    static func main() async {
        do {
            try await run(Options(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("SpeechTextEvaluation: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    struct Options {
        var corpus: URL?
        var runDirectory: URL?
        var engines: [String] = []
        var clips: [String] = []
        var cloud = false

        init(_ arguments: ArraySlice<String>) throws {
            var arguments = arguments
            func value(_ flag: String) throws -> String {
                guard let value = arguments.popFirst() else { throw UsageError("\(flag) needs a value") }
                return value
            }
            while let argument = arguments.popFirst() {
                switch argument {
                case "--corpus": corpus = URL(fileURLWithPath: try value(argument))
                case "--run-dir": runDirectory = URL(fileURLWithPath: try value(argument))
                case "--engines": engines = try value(argument).split(separator: ",").map(String.init)
                case "--clips": clips = try value(argument).split(separator: ",").map(String.init)
                case "--cloud": cloud = true
                default: throw UsageError("unknown argument \(argument)")
                }
            }
        }
    }

    struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? {
            message + "\nusage: SpeechTextEvaluation --corpus <dir> [--run-dir <dir>] [--engines vendor/model,…] [--clips a,…] [--cloud]"
        }
    }

    /// The checkout this tool was built from: the clip descriptions are committed there,
    /// and the run folder goes under its `docs/testing-runs/`.
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @MainActor
    static func run(_ options: Options) async throws {
        guard let corpus = options.corpus else { throw UsageError("--corpus is required") }
        registerLocalSTT()
        registerSpellCheckedJoins()
        let descriptions = try CorpusClip.load(from: repository.appendingPathComponent("SpeechText/SpeechTextTests/Audio"))
        let clips = CorpusClip.recordings(of: descriptions, in: corpus)
            .filter { $0.isSelected(by: options.clips) }
        let engines = CorpusEngine.all
            .filter { ($0.isLocal || options.cloud) && (options.engines.isEmpty || options.engines.contains($0.id)) }
        var folder = options.runDirectory.map { CorpusRunFolder(url: $0) } ?? CorpusRunFolder.new(in: repository)
        folder.baseline = CorpusRunFolder.previous(in: repository, before: folder.url)?.url
        let keys = ProviderKeys.fromEnvironment()
        let runner = options.cloud ? "all" : "local"

        var results = folder.earlierResults(runner: runner, except: clips)
        var loaded: Set<String> = []
        for clip in clips {
            let audio = try? TapAudio(clip: clip, in: corpus)
            for engine in engines {
                for pass in clip.passes {
                    var result = CorpusResult(clip: clip.name, engine: engine.id, engineName: engine.name,
                                              language: pass.label, status: .noAudio)
                    if let audio {
                        if let missing = engine.unavailable(keys: keys) {
                            result.status = missing
                        } else {
                            // The load goes in its own column: a first load specialises the model
                            // for this Mac (nine minutes for Whisper Turbo) and is not the stop's.
                            var loadSeconds: Double?
                            if engine.isLocal, !loaded.contains(engine.id) {
                                print("loading \(engine.model.displayName)…")
                                let start = Date()
                                try await prewarm(engine)
                                loadSeconds = Date().timeIntervalSince(start)
                                loaded.insert(engine.id)
                            }
                            result = await LiveDictation.run(clip: clip, audio: audio, engine: engine, pass: pass,
                                                             keys: keys, traceDirectory: folder.traces)
                            result.loadSeconds = loadSeconds
                        }
                    }
                    print("\(clip.name) · \(engine.id) · \(result.language): \(result.status.rawValue)"
                          + (result.failures.isEmpty ? "" : " ❌ " + result.failures.joined(separator: "; ")))
                    results.append(result)
                    try folder.write(results, runner: runner)
                }
            }
        }
        print("\(folder.url.path)/summary.md")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }

    private static func prewarm(_ engine: CorpusEngine) async throws {
        guard case .onDevice(let kind) = engine.model.delivery else { return }
        let runtime: LocalSTTRuntime = switch kind {
        case .whisperKit: WhisperKitRuntime()
        case .parakeet: ParakeetRuntime()
        }
        try await runtime.prewarm(modelFolder: localModelFolder(for: engine.model.id))
    }
}
