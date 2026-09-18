// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Endpoint

/// Ollama's default listen address. Stored rather than hard-coded so a user running it
/// on another port — or on another Mac on the LAN — can point the app at it.
let ollamaDefaultBaseURL = "http://localhost:11434"

func ollamaBaseURL() -> URL {
    let raw = UserDefaults.standard.string(forKey: SettingsKeys.ollamaBaseURL) ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(string: trimmed.isEmpty ? ollamaDefaultBaseURL : trimmed) ?? URL(string: ollamaDefaultBaseURL)!
}

// MARK: - Catalogue

/// A local chat model worth offering for the rewrite pass.
struct LocalLLMModel: Identifiable, Hashable {
    /// The Ollama tag, e.g. `qwen3:8b` — also the id used in `/api/pull` and `/api/chat`.
    let id: String
    let displayName: String
    /// Download size, read from the Ollama registry manifest on 2026-09-16 rather than
    /// taken from the model card, which rounds.
    let downloadBytes: Int64
    /// Weights have to fit in RAM alongside everything else the user is running. The
    /// floor is roughly twice the download for comfort, not merely the weights.
    let memoryFloorBytes: UInt64
    /// The first Ollama release that can load this model, from Ollama's release notes.
    /// An older daemon does not refuse the pull — it downloads gigabytes and then fails
    /// every request with "unknown model architecture", which the user cannot act on.
    let minimumOllamaVersion: String
    let summary: String

    var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

private let gigabyte: UInt64 = 1_073_741_824

/// Every local chat model on offer, **heaviest first**. Sizes are the Ollama registry
/// manifests, read 2026-09-16.
///
/// Floors leave room for macOS, the KV cache and whatever else the user has open — a
/// model that only just fits pages the moment a browser tab loads, and a rewrite that
/// stalls reads as the app hanging. MoE models are noted because they answer at the
/// speed of their *active* parameters, which is what matters while the user waits.
///
/// Qwen and Gemma only, deliberately: both are trained across many languages and have
/// small builds that are current. Llama 4, Granite and Ministral were left out as weaker
/// outside English or older; `gemma4:e2b/e4b` because their audio and vision encoders
/// make them 7–10 GB, too heavy for the Macs a 2–4B model is meant for; and the models
/// Ollama lists only as `:cloud` (Qwen3.5 397B, MiniMax M2.7, Kimi K3, Mistral Large 3)
/// because they do not run on the Mac at all.
let localLLMModels: [LocalLLMModel] = [
    LocalLLMModel(
        id: "qwen3.5:122b", displayName: "Qwen3.5 122B",
        downloadBytes: 81_370_035_877, memoryFloorBytes: 128 * gigabyte, minimumOllamaVersion: "0.17.4",
        summary: "The largest model that runs on a Mac. Mixture-of-experts with 10B active, so it answers faster than its size suggests."
    ),
    LocalLLMModel(
        id: "gpt-oss:120b", displayName: "gpt-oss 120B",
        downloadBytes: 65_369_818_451, memoryFloorBytes: 96 * gigabyte, minimumOllamaVersion: "0.11.0",
        summary: "OpenAI's open model. Mixture-of-experts with 5B active; its reasoning can be turned down but not off."
    ),
    LocalLLMModel(
        id: "qwen3.6:35b-a3b", displayName: "Qwen3.6 35B",
        downloadBytes: 22_621_314_161, memoryFloorBytes: 36 * gigabyte, minimumOllamaVersion: "0.24.0",
        summary: "Mixture-of-experts with 3B active — large-model knowledge at small-model speed."
    ),
    LocalLLMModel(
        id: "gemma4:31b", displayName: "Gemma 4 31B",
        downloadBytes: 19_868_981_317, memoryFloorBytes: 36 * gigabyte, minimumOllamaVersion: "0.20.0",
        summary: "Google's largest dense Gemma. Strong writing, slower than the mixture-of-experts models."
    ),
    LocalLLMModel(
        id: "gemma4:26b", displayName: "Gemma 4 26B",
        downloadBytes: 18_604_148_235, memoryFloorBytes: 36 * gigabyte, minimumOllamaVersion: "0.20.0",
        summary: "Mixture-of-experts with 4B active. Fast, and a different family to compare Qwen against."
    ),
    LocalLLMModel(
        id: "qwen3.8:27b", displayName: "Qwen3.8 27B",
        downloadBytes: 17_741_871_939, memoryFloorBytes: 32 * gigabyte, minimumOllamaVersion: "0.32.12",
        summary: "The newest Qwen (August 2026), dense. The best text in our test, but 5–14 s per dictation on an M1 Pro — worth it only when you can wait."
    ),
    LocalLLMModel(
        id: "gemma4:12b", displayName: "Gemma 4 12B",
        downloadBytes: 7_556_507_848, memoryFloorBytes: 16 * gigabyte, minimumOllamaVersion: "0.30.5",
        summary: "Best balance in our Ukrainian test: every preset chosen right, fillers gone, identifiers restored, 2–4 s. The pick for 16–32 GB."
    ),
    LocalLLMModel(
        id: "qwen3.5:9b", displayName: "Qwen3.5 9B",
        downloadBytes: 6_594_474_236, memoryFloorBytes: 16 * gigabyte, minimumOllamaVersion: "0.17.4",
        summary: "Handled every test dictation, a step behind Gemma 4 12B (left some fillers in). A little lighter."
    ),
    LocalLLMModel(
        id: "qwen3.5:4b", displayName: "Qwen3.5 4B",
        downloadBytes: 3_389_983_260, memoryFloorBytes: 8 * gigabyte, minimumOllamaVersion: "0.17.4",
        summary: "The best that fits 8 GB, with limits: in our test it turned a plain note into an email and a Ukrainian technical note into English."
    ),
    LocalLLMModel(
        id: "qwen3.5:2b", displayName: "Qwen3.5 2B",
        downloadBytes: 2_741_192_347, memoryFloorBytes: 8 * gigabyte, minimumOllamaVersion: "0.17.4",
        summary: "Not recommended: in our test it switched Ukrainian to Russian, skipped a translation and left fillers in. Only a last resort for a nearly full disk."
    ),
    LocalLLMModel(
        id: "qwen3.5:0.8b", displayName: "Qwen3.5 0.8B",
        downloadBytes: 1_036_046_107, memoryFloorBytes: 4 * gigabyte, minimumOllamaVersion: "0.17.4",
        summary: "Not recommended for Ukrainian. The floor for a Mac that can hold nothing larger."
    ),
]

func localLLMModel(id: String) -> LocalLLMModel? {
    localLLMModels.first { $0.id == id }
}

/// What each tier is offered. See `TierPicks`: "recommended" is the fastest model of good
/// enough quality, "best quality" the strongest the tier can hold, and both are candidate
/// lists so a Mac at the bottom of its tier's memory range, or short on disk, steps down.
///
/// Measured on 2026-09-17 for the tiers an M1 Pro 32 GB can run (entry to plus): six
/// dictations — Ukrainian clean-up, email, translation, a technical note, a spoken list,
/// English clean-up — through the app's own system prompt and parser, on Ollama 0.34.1.
/// Qwen3.5 2B failed outright (Ukrainian turned Russian); Qwen3.5 4B was usable with
/// misroutes; Qwen3.5 9B and Gemma 4 12B handled all six, Gemma a notch cleaner at the
/// same 2–4 s; Qwen3.8 27B wrote the best text but took 5–14 s. The pro / max / ultra
/// picks were not measured (no such hardware here) — Gemma 4 26B leads the pro tier
/// because it is the same family as the 16–32 GB winner, as a mixture-of-experts.
func localLLMPicks(for tier: MacTier) -> TierPicks {
    let floor = ["qwen3.5:4b", "qwen3.5:2b", "qwen3.5:0.8b"]
    switch tier {
    case .intel, .entry:
        return TierPicks(recommended: floor, bestQuality: floor)
    case .standard:
        return TierPicks(recommended: ["gemma4:12b", "qwen3.5:9b"] + floor,
                         bestQuality: ["gemma4:12b", "qwen3.5:9b"] + floor)
    case .plus:
        return TierPicks(recommended: ["gemma4:12b", "qwen3.5:9b"] + floor,
                         bestQuality: ["qwen3.8:27b", "gemma4:12b", "qwen3.5:9b"] + floor)
    case .pro:
        return TierPicks(recommended: ["gemma4:26b", "qwen3.6:35b-a3b", "gemma4:12b"] + floor,
                         bestQuality: ["qwen3.8:27b", "gemma4:31b", "gemma4:12b"] + floor)
    case .max, .ultra:
        // Nothing larger runs locally through Ollama, so a 512 GB Mac Studio gets the
        // same pair as a 128 GB one.
        return TierPicks(recommended: ["gpt-oss:120b", "gemma4:26b", "gemma4:12b"] + floor,
                         bestQuality: ["qwen3.5:122b", "gpt-oss:120b", "qwen3.8:27b", "gemma4:12b"] + floor)
    }
}

/// Whether a running Ollama (`/api/version`, e.g. "0.34.1") is at least `required`.
/// Numeric per component, so 0.32.12 is newer than 0.32.6 — a string comparison gets
/// that backwards. Anything unparseable counts as new enough: a dev build or a future
/// scheme should not lock the user out of a download on a guess.
func ollamaVersion(_ running: String, isAtLeast required: String) -> Bool {
    func parts(_ v: String) -> [Int]? {
        let core = v.split(separator: "-").first.map(String.init) ?? v
        let numbers = core.split(separator: ".").map { Int($0) }
        return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
    }
    guard let have = parts(running), let need = parts(required) else { return true }
    for i in 0 ..< max(have.count, need.count) {
        let a = i < have.count ? have[i] : 0, b = i < need.count ? need[i] : 0
        if a != b { return a > b }
    }
    return true
}

/// Unlike the speech side there is no Intel exclusion: Ollama runs on the GPU via Metal,
/// which Intel Macs have — it is only slow, which the small picks already account for.
func recommendedLocalLLMModel(for capabilities: SystemCapabilities) -> LocalLLMModel? {
    firstFitting(localLLMPicks(for: MacTier(capabilities)).recommended, in: localLLMModels,
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

func bestQualityLocalLLMModel(for capabilities: SystemCapabilities) -> LocalLLMModel? {
    firstFitting(localLLMPicks(for: MacTier(capabilities)).bestQuality, in: localLLMModels,
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

/// How to switch a model's reasoning off, or as far down as it goes.
///
/// Every candidate thinks by default, and the user is waiting on the paste. `none` is
/// honoured by Qwen (2.0 s → 0.22 s for the same clean-up on qwen3:0.6b, Ollama 0.18.1)
/// and accepted by models with no thinking mode, but gpt-oss only takes low / medium /
/// high — for it `low` is the floor.
func ollamaReasoningEffort(for model: String) -> String {
    model.hasPrefix("gpt-oss") ? "low" : "none"
}

// MARK: - Service

struct OllamaInstalledModel: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let sizeBytes: Int64
}

enum OllamaError: LocalizedError {
    case notRunning
    /// The daemon is too old for the model's architecture.
    case needsUpdate(model: String)
    case httpError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Ollama isn't running. Install it from ollama.com and it will start automatically."
        case .needsUpdate(let model): "This Ollama is too old to run \(model). Update Ollama from ollama.com."
        case .httpError(let code, let body): "Ollama error HTTP \(code): \(body)"
        case .invalidResponse: "Unexpected response from Ollama"
        }
    }
}

/// Talks to a local Ollama daemon over its HTTP API. No third-party code: Ollama is a
/// separate program the user installs, not a library this app links.
enum OllamaService {
    /// Short timeouts — this is a loopback connection, and the UI asks "is it running?"
    /// on every Settings appearance. A hung probe would make the pane feel broken.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        return URLSession(configuration: config)
    }()

    /// A model download can run for many minutes on a slow link, so it gets its own
    /// session with no resource timeout at all — the user can cancel, the clock cannot.
    private static let pullSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        return URLSession(configuration: config)
    }()

    static func isRunning() async -> Bool {
        var request = URLRequest(url: ollamaBaseURL().appendingPathComponent("api/version"))
        request.httpMethod = "GET"
        guard let (_, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200 ... 299).contains(http.statusCode)
    }

    /// The daemon's version string, or nil when it is not reachable.
    static func version() async -> String? {
        var request = URLRequest(url: ollamaBaseURL().appendingPathComponent("api/version"))
        request.httpMethod = "GET"
        guard let (data, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    static func installedModels() async throws -> [OllamaInstalledModel] {
        var request = URLRequest(url: ollamaBaseURL().appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        guard let (data, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard (200 ... 299).contains(http.statusCode) else {
            throw OllamaError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { OllamaInstalledModel(name: $0.name, sizeBytes: $0.size) }
    }

    /// Pulls a model, reporting 0…1 as it goes.
    ///
    /// `/api/pull` answers with newline-delimited JSON, one object per progress tick, and
    /// the connection stays open for the whole download — so this reads the byte stream
    /// incrementally rather than awaiting a complete body. `completed`/`total` are absent
    /// on the status-only lines ("pulling manifest", "verifying sha256digest"), which is
    /// why progress is only updated when both are present.
    static func pull(model: String, progress: @escaping (Double) -> Void) async throws {
        var request = URLRequest(url: ollamaBaseURL().appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

        dlog("Ollama", "pull: \(model)")
        let (bytes, response) = try await pullSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard (200 ... 299).contains(http.statusCode) else {
            throw OllamaError.httpError(http.statusCode, "pull refused")
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let error = object["error"] as? String {
                throw OllamaError.httpError(http.statusCode, error)
            }
            if let total = object["total"] as? Int64, total > 0,
               let completed = object["completed"] as? Int64 {
                progress(min(max(Double(completed) / Double(total), 0), 1))
            }
        }
        dlog("Ollama", "pull: \(model) complete")
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let size: Int64
        }
        let models: [Model]
    }
}

// MARK: - Chat provider

/// The rewrite pass against a local Ollama model.
///
/// Uses Ollama's OpenAI-compatible `/v1/chat/completions`, so the request and response
/// shapes are exactly the cloud ones, with reasoning switched off (see the payload).
struct OllamaLLMProvider: LLMChatProvider {
    let model: String

    /// Generous: a 14B model on a cold start has to load several gigabytes off disk
    /// before it emits a token, and the user is watching an overlay meanwhile.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: ollamaBaseURL().appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.3,
            "stream": false,
            // `reasoning_effort` is the switch this endpoint honours — a `think: false` sent
            // here is silently ignored. See `ollamaReasoningEffort` for the values.
            "reasoning_effort": ollamaReasoningEffort(for: model),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "Ollama: sending request, model=\(model), input=\(user.count) chars")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            // A refused loopback connection means the daemon is not up. Say that,
            // rather than surfacing "Could not connect to the server" — the user can act
            // on the first message and not on the second.
            dlog("LLM", "Ollama: \(error.localizedDescription)")
            throw OllamaError.notRunning
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            dlog("LLM", "Ollama: HTTP \(http.statusCode): \(body.prefix(300))")
            // An old daemon given a model newer than itself answers only "unable to load
            // model" (seen on Ollama 0.18.1 with Qwen3.5; the architecture error stays in
            // its server log). The same words also mean out-of-memory, so the version is
            // what decides — "update Ollama" is only said when it is actually too old.
            if body.contains("unable to load model") || body.contains("unknown model architecture"),
               let entry = localLLMModel(id: model),
               let running = await OllamaService.version(),
               !ollamaVersion(running, isAtLeast: entry.minimumOllamaVersion) {
                throw OllamaError.needsUpdate(model: model)
            }
            throw LLMError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let raw = decoded.choices.first?.message.content else { throw LLMError.emptyResponse }

        let text = strippingReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResponse }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        dlog("LLM", "Ollama: done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }
}

/// Removes a leading `<think>…</think>` block.
///
/// A fallback, not the main defence. Current Ollama both honours `reasoning_effort: none`
/// and, when a model reasons anyway, returns it in a separate `reasoning` field. Older
/// Ollama builds and some community model templates put the block inline in the content
/// instead, and left in place it defeats `TextRefinementService.parse` — the
/// `<<mode:NAME>>` marker is no longer leading, so the routing line gets pasted into the
/// user's document along with the model's private deliberation.
///
/// Only a *leading* block is removed, and only a closed one: text that merely contains
/// the word elsewhere is left alone, and an unterminated tag means the reply was cut off
/// rather than that it reasoned, so there is nothing safe to strip.
func strippingReasoning(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for tag in ["think", "thinking", "reasoning"] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard trimmed.hasPrefix(open), let end = trimmed.range(of: close) else { continue }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}
