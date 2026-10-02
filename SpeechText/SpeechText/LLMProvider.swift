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

    /// The provider that serves the pick.
    var vendor: Provider {
        switch self {
        case .groq: .groq
        case .anthropic: .anthropic
        case .openai: .openAI
        case .ollama: .ollama
        }
    }

    /// Local providers run on this Mac and have no key; `LLMConfiguration.isConfigured`
    /// then means "a model is chosen", and a daemon that is not running surfaces as the
    /// request's own error, through the same raw-transcript fallback as any other failure.
    var needsAPIKey: Bool { vendor.descriptor.apiKey != nil }
}

// MARK: - Model catalogue

/// How a model's reasoning is kept out of its reply, where its API has a switch for it.
enum ReasoningOutput: Equatable {
    /// Nothing sent: the model documents no switch, or needs none.
    case unchanged
    /// `include_reasoning: false` — Groq's gpt-oss, which rejects `reasoning_format`.
    case excluded
    /// `reasoning_format: hidden` — Groq's Qwen, whose default `raw` puts `<think>` into
    /// the content ahead of the `<<mode:NAME>>` marker.
    case hidden
}

/// A chat model AI Rewrite can use: who serves it, its picker name, and the request
/// switches measured for it. Which switches a model accepts is exactly what goes wrong —
/// the wrong one is an HTTP 400 and the whole rewrite lost — so they are written down per
/// model here, and no request is built from a check on the model's name. The local
/// entries are derived from `localLLMModels`, so each model is written down once.
struct ChatModelDescriptor: Equatable {
    let provider: LLMProviderType
    let id: String
    let displayName: String
    /// Sent as `reasoning_effort` (Anthropic: `output_config.effort`); nil sends nothing.
    let reasoningEffort: String?
    let reasoningOutput: ReasoningOutput
    /// Anthropic's server-side refusal fallbacks, documented for the Opus 5 / Fable 5 tier.
    let refusalFallbacks: Bool
}

/// Groq: checked against Groq's model and deprecation pages on 2026-09-16. Both Llama
/// models, Qwen3 32B and Kimi K2 were shut down for free and developer accounts between
/// April and August 2026 — the old default among them, so a stored ID for any of those is
/// normalised to `Provider.groq.defaultChatModel` at launch. The two preview models are labelled as
/// such: Groq may withdraw a preview without notice. Groq's reasoning models take
/// different switches, and the wrong one is an HTTP 400 rather than something ignored:
/// gpt-oss rejects `reasoning_format` and has no `none` effort; Qwen defaults to `raw`.
/// MiniMax M2.7 documents no switch, so its reply goes through `strippingReasoning`.
///
/// Anthropic: Fable 5.1 is left out on purpose: it is the slowest and most expensive
/// model, and a dictation clean-up gains nothing from it. Haiku 4.5 is scheduled for
/// retirement no sooner than 2026-10-15 — when it goes, dropping it here lets
/// normalisation move users. `output_config.effort` is rejected by pre-4.6-era models
/// such as Haiku 4.5; elsewhere `low` keeps latency down while leaving adaptive thinking
/// on (disabling it can leak `<thinking>` tags).
///
/// OpenAI: GPT-6 Astra is left out: it is built for long agentic work, and a dictation
/// clean-up would only pay for its latency. `reasoning_effort: none` — measured
/// 2026-09-21 on `gpt-5.6-luna` against the live API: median 1.63 s on the default
/// effort, 0.98 s with `none`, and `low` matched that median with a longer tail. The
/// accepted values are `none / low / medium / high / xhigh`; `minimal` is rejected. Only
/// the 5.6 family was measured, so a model added here without a measurement is sent
/// nothing: an unsupported value costs the whole rewrite, a default effort only time.
let chatModelCatalog: [ChatModelDescriptor] = [
    ChatModelDescriptor(provider: .groq, id: "openai/gpt-oss-120b", displayName: "GPT-OSS 120B",
                        reasoningEffort: "low", reasoningOutput: .excluded, refusalFallbacks: false),
    ChatModelDescriptor(provider: .groq, id: "openai/gpt-oss-20b", displayName: "GPT-OSS 20B (fastest)",
                        reasoningEffort: "low", reasoningOutput: .excluded, refusalFallbacks: false),
    ChatModelDescriptor(provider: .groq, id: "qwen/qwen3.8-27b", displayName: "Qwen3.8 27B (preview)",
                        reasoningEffort: "none", reasoningOutput: .hidden, refusalFallbacks: false),
    ChatModelDescriptor(provider: .groq, id: "minimaxai/minimax-m2.7", displayName: "MiniMax M2.7 (preview)",
                        reasoningEffort: nil, reasoningOutput: .unchanged, refusalFallbacks: false),

    ChatModelDescriptor(provider: .anthropic, id: "claude-sonnet-5", displayName: "Claude Sonnet 5",
                        reasoningEffort: "low", reasoningOutput: .unchanged, refusalFallbacks: false),
    ChatModelDescriptor(provider: .anthropic, id: "claude-opus-5", displayName: "Claude Opus 5",
                        reasoningEffort: "low", reasoningOutput: .unchanged, refusalFallbacks: true),
    ChatModelDescriptor(provider: .anthropic, id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5 (fastest)",
                        reasoningEffort: nil, reasoningOutput: .unchanged, refusalFallbacks: false),

    ChatModelDescriptor(provider: .openai, id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna — fastest",
                        reasoningEffort: "none", reasoningOutput: .unchanged, refusalFallbacks: false),
    ChatModelDescriptor(provider: .openai, id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra — balanced",
                        reasoningEffort: "none", reasoningOutput: .unchanged, refusalFallbacks: false),
    ChatModelDescriptor(provider: .openai, id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol — flagship",
                        reasoningEffort: "none", reasoningOutput: .unchanged, refusalFallbacks: false),
] + localLLMModels.map { local in
    ChatModelDescriptor(provider: .ollama, id: local.id, displayName: local.displayName,
                        reasoningEffort: local.reasoningEffort, reasoningOutput: .unchanged, refusalFallbacks: false)
}

func chatModels(of provider: LLMProviderType) -> [ChatModelDescriptor] {
    chatModelCatalog.filter { $0.provider == provider }
}

/// The catalogue's entry for this model, or nil for an ID it does not list.
func listedChatModel(provider: LLMProviderType, id: String) -> ChatModelDescriptor? {
    chatModelCatalog.first { $0.provider == provider && $0.id == id }
}

/// The model a request is built for: its catalogue entry, or what an unlisted ID is sent.
func chatModel(provider: LLMProviderType, id: String) -> ChatModelDescriptor {
    if let listed = listedChatModel(provider: provider, id: id) { return listed }
    switch provider {
    case .groq, .anthropic, .openai:
        // Normalisation moves a stored cloud ID the catalogue no longer lists to the
        // default at launch, so only an ID nobody measured gets here. It is sent no
        // switch: an unsupported one costs the whole rewrite, a default effort only time.
        return ChatModelDescriptor(provider: provider, id: id, displayName: id, reasoningEffort: nil,
                                   reasoningOutput: .unchanged, refusalFallbacks: false)
    case .ollama:
        // Ollama runs any tag the daemon has. A tag takes the effort of the catalogue
        // family its name begins with (any gpt-oss build takes `gpt-oss:20b`'s `low`), and
        // `none` otherwise — which Qwen honours and a model with no thinking mode accepts.
        let family = chatModels(of: .ollama)
            .map { (name: String($0.id.prefix { $0 != ":" }), model: $0) }
            .filter { id.hasPrefix($0.name) }
            .max { $0.name.count < $1.name.count }
        return ChatModelDescriptor(provider: .ollama, id: id, displayName: id,
                                   reasoningEffort: family?.model.reasoningEffort ?? "none",
                                   reasoningOutput: .unchanged, refusalFallbacks: false)
    }
}

/// The Settings pickers' (id, name) pairs, in catalogue order.
private func chatPickerModels(of provider: LLMProviderType) -> [(id: String, name: String)] {
    chatModels(of: provider).map { (id: $0.id, name: $0.displayName) }
}

let groqChatModels = chatPickerModels(of: .groq)
let anthropicChatModels = chatPickerModels(of: .anthropic)
let openAIChatModels = chatPickerModels(of: .openai)

// MARK: - Protocol

protocol ChatClient {
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
/// URLRequest.timeoutInterval, so we build our own, as the transcribers do.
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
struct OpenAICompatibleChatClient: ChatClient {
    /// The two backends share an endpoint shape but not its parameters.
    enum Dialect {
        /// Groq: classic Chat Completions — `max_tokens` and sampling params accepted.
        case classic
        /// OpenAI's GPT-5.x reasoning models: `max_tokens` and `temperature` are both
        /// rejected with HTTP 400. The output cap moved to `max_completion_tokens`, and
        /// how hard the model thinks before answering is the descriptor's
        /// `reasoningEffort`.
        case reasoning
    }

    let label: String
    let baseURL: URL
    let apiKey: String
    let model: ChatModelDescriptor
    let dialect: Dialect

    /// The request body, built apart from the network so it can be asserted directly.
    /// The switches are the model's descriptor's; see `chatModelCatalog`.
    func payload(system: String, user: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        switch dialect {
        case .classic:
            body["max_tokens"] = 8192
            body["temperature"] = 0.3
        case .reasoning:
            body["max_completion_tokens"] = 8192
        }
        if let effort = model.reasoningEffort {
            body["reasoning_effort"] = effort
        }
        switch model.reasoningOutput {
        case .unchanged: break
        case .excluded: body["include_reasoning"] = false
        case .hidden: body["reasoning_format"] = "hidden"
        }
        return body
    }

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(withJSONObject: payload(system: system, user: user))

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "\(label): sending request, model=\(model.id), input=\(user.count) chars")
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

struct AnthropicChatClient: ChatClient {
    let apiKey: String
    let model: ChatModelDescriptor

    /// The request body, built apart from the network so it can be asserted directly.
    func payload(system: String, user: String) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model.id,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        if let effort = model.reasoningEffort {
            payload["output_config"] = ["effort": effort]
        }
        if model.refusalFallbacks {
            payload["fallbacks"] = "default"
        }
        return payload
    }

    /// The `anthropic-beta` header the body's `fallbacks` needs, or nil.
    var betaHeader: String? {
        model.refusalFallbacks ? "server-side-fallback-2026-07-01" : nil
    }

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let betaHeader {
            request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(system: system, user: user))

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "Anthropic: sending request, model=\(model.id), input=\(user.count) chars")
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
        type.vendor.descriptor.apiKey.map { APIKeyStore.shared.value(for: $0.settingsKey) } ?? ""
    }

    /// The chat model stored for the pick, else its provider's default.
    static func model(for type: LLMProviderType) -> String {
        let setting = type.vendor.descriptor.chatModel
        return setting?.settingsKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? setting?.defaultID ?? ""
    }

    /// True when the selected provider can be called: a non-empty API key for the cloud
    /// providers, a chosen model for Ollama.
    static var isConfigured: Bool {
        let type = providerType
        let value = type.needsAPIKey ? apiKey(for: type) : model(for: type)
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func makeChatClient() throws -> ChatClient {
        let type = providerType
        if type == .ollama {
            let model = model(for: type)
            guard !model.isEmpty else { throw LLMError.noLocalModel }
            return OllamaChatClient(model: chatModel(provider: .ollama, id: model))
        }
        let key = apiKey(for: type).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingAPIKey(type) }
        let model = chatModel(provider: type, id: model(for: type))

        switch type {
        case .groq:
            return OpenAICompatibleChatClient(
                label: "Groq",
                baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                apiKey: key, model: model, dialect: .classic
            )
        case .openai:
            return OpenAICompatibleChatClient(
                label: "OpenAI",
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: key, model: model, dialect: .reasoning
            )
        case .anthropic:
            return AnthropicChatClient(apiKey: key, model: model)
        case .ollama:
            preconditionFailure("handled above — Ollama has no key to check")
        }
    }
}
