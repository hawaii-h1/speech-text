// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable, Identifiable {
    case groq = "groq"
    case anthropic = "anthropic"
    case openai = "openai"
    case ollama = "ollama"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: "Groq"
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        case .ollama: "Ollama — local"
        }
    }

    /// Local providers run on this Mac and have no key; `LLMConfiguration.isConfigured`
    /// then means "a model is chosen", and a daemon that is not running surfaces as the
    /// request's own error, through the same raw-transcript fallback as any other failure.
    var needsAPIKey: Bool { self != .ollama }
}

// MARK: - Model Catalogs

/// Checked against Groq's model and deprecation pages on 2026-09-16. Both Llama models,
/// Qwen3 32B and Kimi K2 were shut down for free and developer accounts between April
/// and August 2026 — the old default among them, so a stored ID for any of those is
/// normalised to `defaultGroqLLMModel` at launch. The two preview models are labelled as
/// such: Groq may withdraw a preview without notice.
let groqChatModels: [(id: String, name: String)] = [
    ("openai/gpt-oss-120b", "GPT-OSS 120B"),
    ("openai/gpt-oss-20b", "GPT-OSS 20B (fastest)"),
    ("qwen/qwen3.8-27b", "Qwen3.8 27B (preview)"),
    ("minimaxai/minimax-m2.7", "MiniMax M2.7 (preview)"),
]

/// Fable 5.1 is left out on purpose: it is the slowest and most expensive model, and a
/// dictation clean-up gains nothing from it. Haiku 4.5 is scheduled for retirement no
/// sooner than 2026-10-15 — when it goes, dropping it here lets normalisation move users.
let anthropicChatModels: [(id: String, name: String)] = [
    ("claude-sonnet-5", "Claude Sonnet 5"),
    ("claude-opus-5", "Claude Opus 5"),
    ("claude-haiku-4-5", "Claude Haiku 4.5 (fastest)"),
]

/// GPT-6 Astra is left out: it is built for long agentic work, and a dictation clean-up
/// would only pay for its latency.
let openAIChatModels: [(id: String, name: String)] = [
    ("gpt-5.6-luna", "GPT-5.6 Luna — fastest"),
    ("gpt-5.6-terra", "GPT-5.6 Terra — balanced"),
    ("gpt-5.6-sol", "GPT-5.6 Sol — flagship"),
]

// MARK: - Protocol

protocol LLMChatProvider {
    /// Sends a single-turn completion and returns the assistant's plain-text reply.
    func complete(system: String, user: String) async throws -> String
}

enum LLMError: LocalizedError {
    case missingAPIKey(LLMProviderType)
    case invalidResponse
    case httpError(Int, String)
    case refused(String?)
    case emptyResponse
    case noLocalModel

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): "No API key set for \(p.displayName)"
        case .invalidResponse: "Invalid response from the LLM API"
        case .httpError(let code, let body): "LLM API error HTTP \(code): \(body)"
        case .refused(let why): "The model declined the request\(why.map { ": \($0)" } ?? "")"
        case .emptyResponse: "The model returned an empty response"
        case .noLocalModel: "No Ollama model selected — pick or download one in Settings"
        }
    }
}

/// Shared session — URLSession.shared enforces its own 60s timeout regardless of
/// URLRequest.timeoutInterval, so we build our own like GroqSTTProvider does.
private let llmSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 90
    config.timeoutIntervalForResource = 180
    return URLSession(configuration: config)
}()

// MARK: - OpenAI-compatible (Groq + OpenAI)

/// Both Groq and OpenAI expose the same `/chat/completions` shape, so one
/// implementation covers them. They diverge on which parameters they accept —
/// see `Dialect`.
struct OpenAICompatibleLLMProvider: LLMChatProvider {
    /// The two backends share an endpoint shape but not its parameters.
    enum Dialect {
        /// Groq: classic Chat Completions — `max_tokens` and sampling params accepted.
        case classic
        /// OpenAI's GPT-5.x reasoning models: `max_tokens` and `temperature` are both
        /// rejected with HTTP 400. The output cap moved to `max_completion_tokens`, and
        /// how hard the model thinks before answering is `reasoning_effort` — see
        /// `reasoningEffort(for:)`.
        case reasoning
    }

    let label: String
    let baseURL: URL
    let apiKey: String
    let model: String
    let dialect: Dialect

    /// The request body, built apart from the network so it can be asserted directly.
    /// Which switches a model accepts is exactly the part of this provider that goes
    /// wrong, and the wrong one is an HTTP 400 — the whole rewrite lost — rather than
    /// something quietly ignored.
    func payload(system: String, user: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        switch dialect {
        case .classic:
            body["max_tokens"] = 8192
            body["temperature"] = 0.3
            // Groq's reasoning models take different switches, and the wrong one is an
            // HTTP 400 rather than something ignored: gpt-oss rejects `reasoning_format`
            // and has no `none` effort; Qwen defaults to `raw`, which puts `<think>` into
            // the content ahead of the `<<mode:NAME>>` marker.
            if model.hasPrefix("openai/gpt-oss") {
                body["reasoning_effort"] = "low"
                body["include_reasoning"] = false
            } else if model.hasPrefix("qwen/") {
                body["reasoning_effort"] = "none"
                body["reasoning_format"] = "hidden"
            }
        case .reasoning:
            body["max_completion_tokens"] = 8192
            if let effort = Self.reasoningEffort(for: model) {
                body["reasoning_effort"] = effort
            }
        }
        return body
    }

    /// How hard a GPT-5.x model is asked to think before rewriting a dictation: not at
    /// all. Sent nothing, it runs on its own default effort and spends about 0.6 s per
    /// dictation on reasoning no one reads — measured 2026-09-21 on `gpt-5.6-luna`
    /// against the live API: median 1.63 s on the default, 0.98 s with `none`, and `low`
    /// matched that median with a longer tail. The user is waiting for the paste, and a
    /// clean-up is not a task that thinking improves.
    ///
    /// The accepted values are `none / low / medium / high / xhigh`; `minimal` is
    /// rejected. Only the 5.6 family was measured, so any other model is sent nothing at
    /// all: an unsupported value costs the whole rewrite, while a default effort only
    /// costs time. Should a later model refuse `none`, the request fails with HTTP 400
    /// and the dictation falls back to the raw transcript with a notice.
    static func reasoningEffort(for model: String) -> String? {
        model.hasPrefix("gpt-5.6") ? "none" : nil
    }

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(withJSONObject: payload(system: system, user: user))

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "\(label): sending request, model=\(model), input=\(user.count) chars")
        let (data, response) = try await llmSession.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        try validatedHTTPResponse(response, data: data, log: "LLM", label: label,
                                  invalidResponse: LLMError.invalidResponse,
                                  httpError: LLMError.httpError)

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        // A model whose reasoning cannot be switched off from here (MiniMax M2.7 on Groq
        // documents no control) may still put it inline; strip it before parsing.
        guard let raw = decoded.choices.first?.message.content else { throw LLMError.emptyResponse }
        let text = strippingReasoning(raw)
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        dlog("LLM", "\(label): done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }
}

/// The `/chat/completions` reply shape, shared by every provider that speaks the
/// OpenAI-compatible dialect: Groq, OpenAI and Ollama.
struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Anthropic

struct AnthropicLLMProvider: LLMChatProvider {
    let apiKey: String
    let model: String

    /// `output_config.effort` is rejected by pre-4.6-era models such as Haiku 4.5.
    private var supportsEffort: Bool {
        !model.hasPrefix("claude-haiku")
    }

    /// Server-side refusal fallbacks are documented for the Opus 5 / Fable 5 tier.
    private var supportsFallbacks: Bool {
        model.contains("opus-5") || model.contains("fable")
    }

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        // Rewriting a dictation is a shallow task — low effort keeps latency down
        // while leaving adaptive thinking on (disabling it can leak <thinking> tags).
        if supportsEffort {
            payload["output_config"] = ["effort": "low"]
        }
        if supportsFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            payload["fallbacks"] = "default"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "Anthropic: sending request, model=\(model), input=\(user.count) chars")
        let (data, response) = try await llmSession.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        try validatedHTTPResponse(response, data: data, log: "LLM", label: "Anthropic",
                                  invalidResponse: LLMError.invalidResponse,
                                  httpError: LLMError.httpError)

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)

        // A policy decline arrives as HTTP 200 — check stop_reason before reading content.
        if decoded.stop_reason == "refusal" {
            dlog("LLM", "Anthropic: refusal (\(decoded.stop_details?.category ?? "unknown"))")
            throw LLMError.refused(decoded.stop_details?.explanation)
        }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        dlog("LLM", "Anthropic: done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
    }
}

// MARK: - Factory

enum LLMConfiguration {
    static var providerType: LLMProviderType {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) ?? LLMProviderType.groq.rawValue
        return LLMProviderType(rawValue: raw) ?? .groq
    }

    static func apiKey(for type: LLMProviderType) -> String {
        let keys = APIKeyStore.shared
        switch type {
        case .groq: return keys.value(for: SettingsKeys.groqAPIKey)
        case .anthropic: return keys.value(for: SettingsKeys.anthropicAPIKey)
        case .openai: return keys.value(for: SettingsKeys.openAIAPIKey)
        case .ollama: return ""
        }
    }

    static func model(for type: LLMProviderType) -> String {
        let defaults = UserDefaults.standard
        switch type {
        case .groq:
            return defaults.string(forKey: SettingsKeys.groqLLMModel) ?? defaultGroqLLMModel
        case .anthropic:
            return defaults.string(forKey: SettingsKeys.anthropicModel) ?? defaultAnthropicModel
        case .openai:
            return defaults.string(forKey: SettingsKeys.openAIModel) ?? defaultOpenAIModel
        case .ollama:
            return defaults.string(forKey: SettingsKeys.ollamaModel) ?? ""
        }
    }

    /// True when the selected provider can be called: a non-empty API key for the cloud
    /// providers, a chosen model for Ollama.
    static var isConfigured: Bool {
        let type = providerType
        let value = type.needsAPIKey ? apiKey(for: type) : model(for: type)
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func makeProvider() throws -> LLMChatProvider {
        let type = providerType
        if type == .ollama {
            let model = model(for: type)
            guard !model.isEmpty else { throw LLMError.noLocalModel }
            return OllamaLLMProvider(model: model)
        }
        let key = apiKey(for: type).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingAPIKey(type) }
        let model = model(for: type)

        switch type {
        case .groq:
            return OpenAICompatibleLLMProvider(
                label: "Groq",
                baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                apiKey: key, model: model, dialect: .classic
            )
        case .openai:
            return OpenAICompatibleLLMProvider(
                label: "OpenAI",
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: key, model: model, dialect: .reasoning
            )
        case .anthropic:
            return AnthropicLLMProvider(apiKey: key, model: model)
        case .ollama:
            preconditionFailure("handled above — Ollama has no key to check")
        }
    }
}

/// Defaults are the fast end of each catalogue that still rewrites well: the user is
/// waiting on the paste. Groq's own replacement for the retired Llama 3.3 70B.
let defaultGroqLLMModel = "openai/gpt-oss-120b"
let defaultAnthropicModel = "claude-sonnet-5"
let defaultOpenAIModel = "gpt-5.6-luna"
