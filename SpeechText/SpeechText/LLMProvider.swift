// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable, Identifiable {
    case groq = "groq"
    case anthropic = "anthropic"
    case openai = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: "Groq"
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        }
    }
}

// MARK: - Model Catalogs

let groqChatModels: [(id: String, name: String)] = [
    ("llama-3.3-70b-versatile", "Llama 3.3 70B"),
    ("openai/gpt-oss-120b", "GPT-OSS 120B"),
    ("openai/gpt-oss-20b", "GPT-OSS 20B"),
    ("moonshotai/kimi-k2-instruct-0905", "Kimi K2"),
    ("qwen/qwen3-32b", "Qwen3 32B"),
    ("llama-3.1-8b-instant", "Llama 3.1 8B (fastest)"),
]

let anthropicChatModels: [(id: String, name: String)] = [
    ("claude-opus-5", "Claude Opus 5"),
    ("claude-sonnet-5", "Claude Sonnet 5"),
    ("claude-haiku-4-5", "Claude Haiku 4.5 (fastest)"),
]

let openAIChatModels: [(id: String, name: String)] = [
    ("gpt-5.6-sol", "GPT-5.6 Sol — flagship"),
    ("gpt-5.6-terra", "GPT-5.6 Terra — balanced"),
    ("gpt-5.6-luna", "GPT-5.6 Luna — fastest"),
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

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): "No API key set for \(p.displayName)"
        case .invalidResponse: "Invalid response from the LLM API"
        case .httpError(let code, let body): "LLM API error HTTP \(code): \(body)"
        case .refused(let why): "The model declined the request\(why.map { ": \($0)" } ?? "")"
        case .emptyResponse: "The model returned an empty response"
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
        /// rejected with HTTP 400. The output cap moved to `max_completion_tokens`.
        case reasoning
    }

    let label: String
    let baseURL: URL
    let apiKey: String
    let model: String
    let dialect: Dialect

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        switch dialect {
        case .classic:
            payload["max_tokens"] = 8192
            payload["temperature"] = 0.3
        case .reasoning:
            payload["max_completion_tokens"] = 8192
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "\(label): sending request, model=\(model), input=\(user.count) chars")
        let (data, response) = try await llmSession.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            dlog("LLM", "\(label): HTTP \(http.statusCode): \(body.prefix(300))")
            throw LLMError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        dlog("LLM", "\(label): done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
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

        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            dlog("LLM", "Anthropic: HTTP \(http.statusCode): \(body.prefix(300))")
            throw LLMError.httpError(http.statusCode, body)
        }

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
        let defaults = UserDefaults.standard
        switch type {
        case .groq: return defaults.string(forKey: SettingsKeys.groqAPIKey) ?? ""
        case .anthropic: return defaults.string(forKey: SettingsKeys.anthropicAPIKey) ?? ""
        case .openai: return defaults.string(forKey: SettingsKeys.openAIAPIKey) ?? ""
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
        }
    }

    /// True when the selected provider has a non-empty API key.
    static var isConfigured: Bool {
        !apiKey(for: providerType).trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func makeProvider() throws -> LLMChatProvider {
        let type = providerType
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
        }
    }
}

let defaultGroqLLMModel = "llama-3.3-70b-versatile"
let defaultAnthropicModel = "claude-opus-5"
let defaultOpenAIModel = "gpt-5.6-terra"
