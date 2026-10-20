// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates

/// AI Rewrite through the local chat models, against a cloud model as the reference — the
/// measurement the built-in local LLM had to earn its place with (docs/specs/
/// 2026-10-16-built-in-local-llm.md, phase 0).
///
///     SpeechTextEvaluation --rewrite <fixtures.json> --runs <dir> --models <dir>
///                          [--engines id,…] [--fixtures id,…] [--repeat n] [--llama-server <path>]
///
/// The fixtures are text: AI Rewrite's input is a transcript, so no audio is needed. Each
/// goes through the app's own system prompt (the built-in presets — never the user's),
/// user message and parser, and `polishedReply` with an empty Dictionary, exactly as
/// `TextRefinementService` sends and reads it. `--models` holds the GGUF files by their
/// catalogue file names; a model not there is a `not installed` row. The reference is
/// Groq's `openai/gpt-oss-120b`, with `GROQ_API_KEY` from the environment.
///
/// `--llama-server` also checks each family's hand-written prompt against the model's own
/// Jinja template, rendered by that llama-server (`--jinja`, `/apply-template`): the two
/// strings and their token IDs must be identical.
///
/// Writes `rewrite-results.json` and `rewrite-summary.md` into a new folder under `--runs`.
enum RewriteEvaluation {

    struct Fixture: Codable {
        struct Context: Codable {
            var appName: String?
            var bundleID: String?
            var windowTitle: String?
            var fieldLabel: String?
        }
        var id: String
        var note: String?
        var kind: String?
        var transcript: String?
        var selection: String?
        var instruction: String?
        var context: Context?
        var vocabulary: [String]?
        /// The modes a right answer may report; the first is the expected one.
        var modes: [String]
        /// `uk`, `en`, or `any`.
        var language: String
        var mustKeep: [String]
        var mustNotAppear: [String]

        var isEdit: Bool { kind == "edit" }
    }

    struct Row: Codable {
        var fixture: String
        var engine: String
        var attempt: Int
        var status: String          // ok / failed / not installed / no key / error
        var reply: String?
        /// What the model wrote, before the app's parser — to see a marker it got wrong.
        var raw: String?
        var mode: String?
        var routed: Bool?
        var missing: [String] = []
        var unwanted: [String] = []
        var russian: Bool = false
        var wrongLanguage: Bool = false
        var reasoningLeak: Bool = false
        var error: String?
        var promptTokens: Int?
        var cachedPromptTokens: Int?
        var outputTokens: Int?
        var promptSeconds: Double?
        var generationSeconds: Double?
        var totalSeconds: Double?
        var finished: Bool?

        /// The text is right, and the mode, when the model reported one the app could read,
        /// is one the fixture allows. A missing marker costs History its prompt name, not
        /// the user their text, so it is counted apart (`markerless`).
        var passed: Bool {
            status == "ok" && (routed == true || mode == nil) && missing.isEmpty && unwanted.isEmpty
                && !russian && !wrongLanguage && !reasoningLeak
        }

        var markerless: Bool { status == "ok" && mode == nil }
    }

    struct EngineInfo: Codable {
        var engine: String
        var name: String
        var loadSeconds: Double?
        var footprintAfterLoadMB: Double?
        var footprintPeakMB: Double?
        var fileBytes: Int64?
        var templateCheck: String?
    }

    struct Report: Codable {
        var date: Date
        var machine: String
        var llamaBuild: String
        var sampling: LlamaSampling
        var contextLength: Int
        var engines: [EngineInfo]
        var rows: [Row]
    }

    static let reference = "groq/openai/gpt-oss-120b"
    static let llamaBuild = "b11696"
    static let contextLength = 8192
    /// The reply's own budget; `ChatTemplates.reasoningAllowance` comes on top for Harmony.
    static let maxTokens = 1024

    // MARK: - Run

    @MainActor
    static func run(_ arguments: ArraySlice<String>) async throws {
        var arguments = arguments
        var fixturesURL: URL?, runs: URL?, models: URL?, llamaServer: URL?
        var engineFilter: [String] = [], fixtureFilter: [String] = []
        var repeats = 1
        var sampling = LlamaSampling.rewrite
        func value(_ flag: String) throws -> String {
            guard let value = arguments.popFirst() else { throw SpeechTextEvaluation.UsageError("\(flag) needs a value") }
            return value
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--rewrite": fixturesURL = URL(fileURLWithPath: try value(argument))
            case "--runs": runs = URL(fileURLWithPath: try value(argument))
            case "--models": models = URL(fileURLWithPath: try value(argument))
            case "--engines": engineFilter = try value(argument).split(separator: ",").map(String.init)
            case "--fixtures": fixtureFilter = try value(argument).split(separator: ",").map(String.init)
            case "--repeat": repeats = max(1, Int(try value(argument)) ?? 1)
            case "--llama-server": llamaServer = URL(fileURLWithPath: try value(argument))
            case "--greedy": sampling.temperature = 0
            default: throw SpeechTextEvaluation.UsageError("unknown argument \(argument)")
            }
        }
        guard let fixturesURL, let runs, let models else {
            throw SpeechTextEvaluation.UsageError("--rewrite, --runs and --models are required")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturesURL))
            .filter { fixtureFilter.isEmpty || fixtureFilter.contains($0.id) }
        let folder = runs.appendingPathComponent(runFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let presets = PromptPresetStore.builtInDefaults
        let system = TextRefinementService.buildSystemPrompt(presets: presets, defaultPresetID: nil)
        let editSystem = TextRefinementService.buildEditSystemPrompt(presets: presets)

        var report = Report(date: Date(), machine: machineDescription(), llamaBuild: llamaBuild,
                            sampling: sampling, contextLength: contextLength, engines: [], rows: [])
        func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: folder.appendingPathComponent("rewrite-results.json"), options: .atomic)
            try summary(report, fixtures: fixtures).write(to: folder.appendingPathComponent("rewrite-summary.md"),
                                                          atomically: true, encoding: .utf8)
        }

        // The reference first: it says what a good answer to each fixture looks like.
        let engines = [reference] + localChatModels.reversed().map(\.id)
        for engine in engines where engineFilter.isEmpty || engineFilter.contains(engine) {
            if engine == reference {
                report.engines.append(EngineInfo(engine: engine, name: "Groq gpt-oss 120B"))
                let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"] ?? ""
                let client = OpenAICompatibleChatClient(
                    label: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                    apiKey: key, model: chatModel(provider: .groq, id: "openai/gpt-oss-120b"), dialect: .classic)
                for fixture in fixtures {
                    for attempt in 1...repeats {
                        var row = Row(fixture: fixture.id, engine: engine, attempt: attempt, status: "no key")
                        if !key.isEmpty {
                            let start = Date()
                            do {
                                let (sys, user) = messages(fixture, system: system, editSystem: editSystem)
                                // Retries: a dropped connection or Groq's per-minute limit is not
                                // the model's answer. Its free tier allows a few requests a minute.
                                var reply: ChatReply?
                                for wait in [0, 5, 20, 40, 60] as [UInt64] {
                                    try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                                    do { reply = try await client.complete(system: sys, user: user); break } catch {
                                        if wait == 60 { throw error }
                                    }
                                }
                                guard let reply else { throw LLMError.emptyResponse }
                                row = judged(fixture, raw: reply.text, engine: engine, attempt: attempt, presets: presets)
                                row.promptTokens = reply.usage?.inputTokens
                                row.outputTokens = reply.usage?.outputTokens
                            } catch {
                                row.status = "error"; row.error = error.localizedDescription
                            }
                            row.totalSeconds = Date().timeIntervalSince(start)
                        }
                        print(line(row)); report.rows.append(row); try save()
                    }
                }
                continue
            }

            guard let model = localChatModel(id: engine) else { continue }
            var info = EngineInfo(engine: engine, name: model.displayName)
            let file = models.appendingPathComponent(model.file)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64,
                  size == model.downloadBytes else {
                info.templateCheck = "not installed"
                report.engines.append(info)
                for fixture in fixtures {
                    report.rows.append(Row(fixture: fixture.id, engine: engine, attempt: 1, status: "not installed"))
                }
                print("\(engine): not installed (\(file.path))"); try save()
                continue
            }
            info.fileBytes = size
            print("loading \(model.displayName)…")
            let runtime = LocalLlamaRuntime()
            info.loadSeconds = try await runtime.load(path: file.path, family: model.family, contextLength: contextLength)
            info.footprintAfterLoadMB = megabytes(processFootprintBytes())
            if let llamaServer {
                info.templateCheck = await templateCheck(model: model, file: file, server: llamaServer, runtime: runtime,
                                                        system: system, fixtures: fixtures)
                print("template check \(engine): \(info.templateCheck ?? "—")")
            }
            var peak = processFootprintBytes()
            for fixture in fixtures {
                for attempt in 1...repeats {
                    let (sys, user) = messages(fixture, system: fixture.isEdit ? editSystem : system, editSystem: editSystem)
                    let start = Date()
                    var row: Row
                    do {
                        let completion = try await runtime.complete(system: sys, user: user, maxTokens: maxTokens, sampling: sampling)
                        row = judged(fixture, raw: completion.reply, engine: engine, attempt: attempt, presets: presets)
                        row.reasoningLeak = row.reasoningLeak || leaksReasoning(completion.reply)
                        row.promptTokens = completion.promptTokens
                        row.cachedPromptTokens = completion.cachedPromptTokens
                        // Everything the model wrote, markers included: what an empty or odd
                        // reply was made of.
                        row.raw = completion.generated
                        row.outputTokens = completion.outputTokens
                        row.promptSeconds = completion.promptSeconds
                        row.generationSeconds = completion.generationSeconds
                        row.finished = completion.finished
                        if !completion.finished { row.status = row.status == "ok" ? "cut off" : row.status }
                    } catch {
                        row = Row(fixture: fixture.id, engine: engine, attempt: attempt, status: "error",
                                  error: error.localizedDescription)
                    }
                    row.totalSeconds = Date().timeIntervalSince(start)
                    peak = max(peak, processFootprintBytes())
                    print(line(row)); report.rows.append(row)
                    info.footprintPeakMB = megabytes(peak)
                    try save()
                }
            }
            report.engines.append(info)
            await runtime.unload()
            try save()
        }
        try save()
        print(folder.appendingPathComponent("rewrite-summary.md").path)
    }

    // MARK: - One fixture

    /// The system prompt and user message `TextRefinementService` would send.
    static func messages(_ fixture: Fixture, system: String, editSystem: String) -> (String, String) {
        let context = fixture.context.map {
            FocusContext(appName: $0.appName, bundleID: $0.bundleID, windowTitle: $0.windowTitle, fieldLabel: $0.fieldLabel)
        }
        let vocabulary = Vocabulary.promptBlock((fixture.vocabulary ?? []).map { VocabularyEntry(term: $0) })
        if fixture.isEdit {
            return (editSystem, TextRefinementService.editUserMessage(
                selection: fixture.selection ?? "", instruction: fixture.instruction, context: context, vocabulary: vocabulary))
        }
        return (system, TextRefinementService.userMessage(transcript: fixture.transcript ?? "", context: context,
                                                          vocabulary: vocabulary))
    }

    /// The reply read as the app reads it, and checked against the fixture.
    static func judged(_ fixture: Fixture, raw: String, engine: String, attempt: Int, presets: [PromptPreset]) -> Row {
        let names = presets.map(\.name) + (fixture.isEdit
            ? [TextRefinementService.editDefaultModeName, TextRefinementService.editCustomModeName] : [])
        let parsed = TextRefinementService.parse(raw, presetNames: names)
        let text = TextRefinementService.polishedReply(parsed.text, dictionary: [], replacements: [], dashStyle: .enDash)
        var row = Row(fixture: fixture.id, engine: engine, attempt: attempt, status: text.isEmpty ? "failed" : "ok")
        row.reply = text
        row.raw = raw
        row.mode = parsed.presetName
        row.routed = parsed.presetName.map { mode in fixture.modes.contains { $0.caseInsensitiveCompare(mode) == .orderedSame } } ?? false
        let folded = text.folding(options: [.caseInsensitive], locale: nil)
        row.missing = fixture.mustKeep.filter { !folded.contains($0.folding(options: [.caseInsensitive], locale: nil)) }
        row.unwanted = fixture.mustNotAppear.filter { folded.contains($0.folding(options: [.caseInsensitive], locale: nil)) }
        row.russian = fixture.language != "en" && isRussian(text)
        row.wrongLanguage = !text.isEmpty && {
            switch fixture.language {
            case "uk": return cyrillicShare(text) < 0.5
            case "en": return cyrillicShare(text) > 0.1
            default: return false
            }
        }()
        row.reasoningLeak = leaksReasoning(raw)
        return row
    }

    /// Letters Ukrainian never writes (ы, э, ъ, ё) or a handful of Russian function words —
    /// the drift weak models show on Ukrainian input.
    static func isRussian(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { "ыэъёЫЭЪЁ".unicodeScalars.contains($0) }) { return true }
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["это", "что", "как", "который", "когда", "сейчас", "нужно", "если"])
    }

    static func cyrillicShare(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }
        return Double(cyrillic.count) / Double(letters.count)
    }

    static func leaksReasoning(_ text: String) -> Bool {
        ["<think>", "</think>", "<|channel", "<channel|>", "<|message|>", "<|start|>", "<|end|>", "<|im_", "<turn|>", "<|turn>"]
            .contains { text.contains($0) }
    }

    // MARK: - Template check

    /// Renders the first fixture's messages with the model's own Jinja template in
    /// llama-server and compares string and token IDs with ours.
    static func templateCheck(model: LocalChatModel, file: URL, server: URL, runtime: LocalLlamaRuntime,
                              system: String, fixtures: [Fixture]) async -> String {
        let port = 18_765
        let process = Process()
        process.executableURL = server
        process.arguments = ["-m", file.path, "--jinja", "--port", "\(port)", "-c", "2048", "-ngl", "0",
                             "--no-warmup", "--log-disable"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "server did not start: \(error.localizedDescription)" }
        defer { process.terminate(); process.waitUntilExit() }

        let fixture = fixtures.first { !$0.isEdit } ?? fixtures[0]
        let (_, user) = messages(fixture, system: system, editSystem: system)
        var kwargs: [String: Any] = [:]
        switch model.family {
        case .qwen: kwargs["enable_thinking"] = false
        case .gemma4: kwargs["enable_thinking"] = false
        case .harmony: kwargs["reasoning_effort"] = "low"
        }
        let body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "chat_template_kwargs": kwargs,
        ]
        var theirs: String?
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/apply-template")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompt = json["prompt"] as? String else { continue }
            theirs = prompt
            break
        }
        guard let theirs else { return "server gave no template" }
        // llama-server leaves the BOS out of the text and adds it when it tokenizes, where
        // the model asks for one (Gemma); ours writes it into the text. So the strings may
        // differ by exactly that, and the tokens are what must be equal.
        let ours = ChatTemplates.render(model.family, system: system, user: user)
        let oursTokens = (try? await runtime.tokenize(ours)) ?? []
        let theirsTokens = (try? await runtime.tokenize(theirs, addSpecial: true)) ?? []
        if !oursTokens.isEmpty, oursTokens == theirsTokens {
            return "identical tokens (\(oursTokens.count))" + (ours == theirs ? "" : ", BOS written as text")
        }
        let common = zip(ours, theirs).prefix { $0 == $1 }.count
        let oursTail = String(ours.dropFirst(common).prefix(80))
        let theirsTail = String(theirs.dropFirst(common).prefix(80))
        return "DIFFERENT at character \(common) — ours: \(oursTail.debugDescription), template: \(theirsTail.debugDescription); "
            + "tokens \(oursTokens.count) vs \(theirsTokens.count)"
    }

    // MARK: - Summary

    static func summary(_ report: Report, fixtures: [Fixture]) -> String {
        var out = "# AI Rewrite on this Mac — llama.cpp \(report.llamaBuild)\n\n"
        out += "\(ISO8601DateFormatter().string(from: report.date)) · \(report.machine) · context \(report.contextLength), "
        out += "top-k \(report.sampling.topK), temperature \(report.sampling.temperature), top-p \(report.sampling.topP), seed \(report.sampling.seed)\n\n"
        out += "Fixtures are generated text (SpeechTextTests/Rewrite/rewrite-fixtures.json), cleaner than real speech.\n\n"
        out += "| Engine | passed | routed | no marker | must-keep misses | unwanted | Russian | wrong language | reasoning leak | cut off / errors | median s | p90 s | load s | footprint MB excl. weights (loaded / peak) | template |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for engine in report.engines {
            let rows = report.rows.filter { $0.engine == engine.engine }
            let ran = rows.filter { $0.status != "not installed" && $0.status != "no key" }
            guard !ran.isEmpty else {
                out += "| \(engine.name) | — | | | | | | | | | | | | | \(engine.templateCheck ?? rows.first?.status ?? "") |\n"
                continue
            }
            let times = ran.compactMap(\.totalSeconds).sorted()
            func pct(_ p: Double) -> String {
                guard !times.isEmpty else { return "—" }
                return String(format: "%.1f", times[min(times.count - 1, Int(Double(times.count - 1) * p))])
            }
            let count = ran.count
            out += "| \(engine.name) | \(ran.filter(\.passed).count)/\(count) | \(ran.filter { $0.routed == true }.count)/\(count)"
            out += " | \(ran.filter(\.markerless).count) | \(ran.filter { !$0.missing.isEmpty }.count) | \(ran.filter { !$0.unwanted.isEmpty }.count)"
            out += " | \(ran.filter(\.russian).count) | \(ran.filter(\.wrongLanguage).count) | \(ran.filter(\.reasoningLeak).count)"
            out += " | \(ran.filter { $0.status == "cut off" || $0.status == "error" || $0.status == "failed" }.count)"
            out += " | \(pct(0.5)) | \(pct(0.9)) | \(engine.loadSeconds.map { String(format: "%.1f", $0) } ?? "—")"
            out += " | \(engine.footprintAfterLoadMB.map { String(format: "%.0f", $0) } ?? "—") / \(engine.footprintPeakMB.map { String(format: "%.0f", $0) } ?? "—")"
            out += " | \(engine.templateCheck ?? "—") |\n"
        }
        out += "\n## Per fixture\n"
        for fixture in fixtures {
            out += "\n### \(fixture.id)\n\n\(fixture.note ?? "")  \nExpected: \(fixture.modes.joined(separator: " / "))\n\n"
            for row in report.rows where row.fixture == fixture.id && row.status != "not installed" {
                let flags = [row.routed == false && row.mode != nil ? "mode \(row.mode ?? "")" : nil,
                             row.markerless ? "no marker (\(markerLine(row.raw)))" : nil,
                             row.missing.isEmpty ? nil : "missing \(row.missing.joined(separator: ", "))",
                             row.unwanted.isEmpty ? nil : "unwanted \(row.unwanted.joined(separator: ", "))",
                             row.russian ? "Russian" : nil, row.wrongLanguage ? "wrong language" : nil,
                             row.reasoningLeak ? "reasoning leaked" : nil,
                             row.status == "ok" ? nil : row.status + (row.error.map { ": \($0)" } ?? "")].compactMap { $0 }
                out += "- **\(row.engine)** \(row.totalSeconds.map { String(format: "%.1f s", $0) } ?? "") "
                out += flags.isEmpty ? "✓" : "❌ " + flags.joined(separator: "; ")
                out += "\n\n  > " + (row.reply ?? "").replacingOccurrences(of: "\n", with: "\n  > ") + "\n"
            }
        }
        return out
    }

    static func line(_ row: Row) -> String {
        "\(row.fixture) · \(row.engine): \(row.passed ? "✓" : "❌ \(row.status)")"
            + (row.mode.map { " [\($0)]" } ?? "") + (row.totalSeconds.map { String(format: " %.1fs", $0) } ?? "")
    }

    /// The first line of the raw reply, which is where the marker should have been.
    static func markerLine(_ raw: String?) -> String {
        let first = (raw ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    static func runFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: Date()) + "_rewrite"
    }

    static func machineDescription() -> String {
        let capabilities = SystemCapabilities.current()
        return "\(capabilities.chipName), \(capabilities.memoryGB) GB"
    }
}
