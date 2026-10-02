// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A company or source that serves models: a cloud vendor, Apple's recogniser, the user's
/// Mac, or the Ollama app on it.
///
/// Not the user's pick: `STTProviderType` and `LLMProviderType` are what the Speech and AI
/// Rewrite pickers store, and each maps to its provider through an exhaustive `vendor`.
/// Groq and OpenAI serve both, with one key.
enum Provider: String, CaseIterable, Hashable, Identifiable {
    case apple
    case groq
    case elevenLabs
    case anthropic
    case openAI
    case local
    case ollama

    var id: String { rawValue }

    /// Everything the app knows about the provider, in one place. Every field of
    /// `ProviderDescriptor` is required, so a new case does not build until it is
    /// described in full; the key list, the key check, the key shapes, the stored model
    /// keys and their normalisation are derived from it. Key pages and dialogs checked
    /// against each vendor on 2026-09-19.
    ///
    /// A default model is a pointer into the catalogue, written here and nowhere else.
    /// The catalogue entries carry literal IDs, so moving a default never removes a
    /// model, and an install that stored the old one keeps it — except `localSTTModel`,
    /// which nothing writes until the user picks: see `preserveInstalledLocalModel`.
    /// Chat defaults are the fast end of each catalogue that still rewrites well — the
    /// user is waiting on the paste; Groq's is its own replacement for the retired
    /// Llama 3.3 70B.
    var descriptor: ProviderDescriptor {
        switch self {
        case .apple:
            ProviderDescriptor(displayName: "Apple", roles: [.speech], apiKey: nil,
                               speechModel: ModelSetting(settingsKey: nil, defaultID: appleSpeechModelID),
                               chatModel: nil)
        case .groq:
            ProviderDescriptor(displayName: "Groq", roles: [.speech, .chat], apiKey: APIKeyDescriptor(
                settingsKey: SettingsKeys.groqAPIKey,
                keysPage: URL(string: "https://console.groq.com/keys")!, freePlan: true,
                createButton: "Create API Key", createNote: "Copy the key.",
                prefix: "gsk_", sample: "gsk_a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6",
                verification: KeyVerification(url: URL(string: "https://api.groq.com/openai/v1/models")!,
                                              header: .bearer)),
                speechModel: ModelSetting(settingsKey: SettingsKeys.groqModel, defaultID: "whisper-large-v3-turbo"),
                chatModel: ModelSetting(settingsKey: SettingsKeys.groqLLMModel, defaultID: "openai/gpt-oss-120b"))
        case .elevenLabs:
            ProviderDescriptor(displayName: "ElevenLabs", roles: [.speech], apiKey: APIKeyDescriptor(
                settingsKey: SettingsKeys.elevenLabsAPIKey,
                keysPage: URL(string: "https://elevenlabs.io/app/developers/api-keys")!, freePlan: false,
                createButton: "Create Key", createNote: "Give it **Speech to Text** access, then copy the key.",
                prefix: "sk_", sample: "sk_a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6",
                verification: KeyVerification(url: URL(string: "https://api.elevenlabs.io/v1/models")!,
                                              header: .named("xi-api-key"))),
                speechModel: ModelSetting(settingsKey: SettingsKeys.elevenLabsModel, defaultID: "scribe_v2"),
                chatModel: nil)
        case .anthropic:
            ProviderDescriptor(displayName: "Anthropic", roles: [.chat], apiKey: APIKeyDescriptor(
                settingsKey: SettingsKeys.anthropicAPIKey,
                keysPage: URL(string: "https://platform.claude.com/settings/keys")!, freePlan: false,
                createButton: "Create key",
                createNote: "Pick a workspace, set expiry to **Never**, then copy the key.",
                prefix: "sk-ant-", sample: "sk-ant-api03-a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6",
                verification: KeyVerification(url: URL(string: "https://api.anthropic.com/v1/models")!,
                                              header: .named("x-api-key"),
                                              extraHeaders: ["anthropic-version": "2023-06-01"])),
                speechModel: nil,
                chatModel: ModelSetting(settingsKey: SettingsKeys.anthropicModel, defaultID: "claude-sonnet-5"))
        case .openAI:
            ProviderDescriptor(displayName: "OpenAI", roles: [.speech, .chat], apiKey: APIKeyDescriptor(
                settingsKey: SettingsKeys.openAIAPIKey,
                keysPage: URL(string: "https://platform.openai.com/api-keys")!, freePlan: false,
                createButton: "Create new secret key",
                createNote: "Keep permissions on **All**, then copy the key. Needs credit in Billing.",
                prefix: "sk-", sample: "sk-proj-a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6",
                verification: KeyVerification(url: URL(string: "https://api.openai.com/v1/models")!,
                                              header: .bearer)),
                speechModel: ModelSetting(settingsKey: SettingsKeys.openAISTTModel, defaultID: "gpt-transcribe"),
                chatModel: ModelSetting(settingsKey: SettingsKeys.openAIModel, defaultID: "gpt-5.6-luna"))
        case .local:
            // The default is Parakeet, not the head of the catalogue: it is what every
            // Apple Silicon Mac is recommended. Moving it is not free. Anyone who *chose*
            // a model keeps it, but nothing writes `localSTTModel` until the user touches
            // the picker, so an install that never chose reads straight through to this,
            // and a moved default would point it at a model it has not downloaded. That is
            // what `preserveInstalledLocalModel()` (Settings.swift) is for; read it first.
            ProviderDescriptor(displayName: "Local", roles: [.speech], apiKey: nil,
                               speechModel: ModelSetting(settingsKey: SettingsKeys.localSTTModel,
                                                         defaultID: parakeetV3ModelID),
                               chatModel: nil)
        case .ollama:
            // Any model the daemon has, so a stored tag is never checked against a list.
            ProviderDescriptor(displayName: "Ollama", roles: [.chat], apiKey: nil, speechModel: nil,
                               chatModel: ModelSetting(settingsKey: SettingsKeys.ollamaModel, defaultID: "",
                                                       normalized: false))
        }
    }

    var displayName: String { descriptor.displayName }

    /// The speech model used while none is stored; empty for a provider with none.
    var defaultSpeechModel: String { descriptor.speechModel?.defaultID ?? "" }
    /// The chat model used while none is stored; empty for a provider with none.
    var defaultChatModel: String { descriptor.chatModel?.defaultID ?? "" }

    /// The phrase the retry notice uses — "a Groq API key", "an OpenAI API key".
    var apiKeyPhrase: String {
        let article = "AEIOU".contains(displayName.prefix(1)) ? "an" : "a"
        return "\(article) \(displayName) API key"
    }
}

/// What the app knows about a provider. See `Provider.descriptor`.
struct ProviderDescriptor {
    /// The company, as Settings, setup and History name it.
    let displayName: String
    /// The steps it can serve. A provider serving both has one key for both.
    let roles: ProviderRoles
    /// Its API key, or nil when it needs none.
    let apiKey: APIKeyDescriptor?
    /// The speech model the user picks, or nil when it serves no speech.
    let speechModel: ModelSetting?
    /// The chat model the user picks, or nil when it serves no AI Rewrite.
    let chatModel: ModelSetting?
}

/// Where the user's pick of one of a provider's models is stored, and what is used
/// while nothing is.
struct ModelSetting {
    /// Its `SettingsKeys` name, which is in `portable`; nil when there is nothing to
    /// pick (Apple's recogniser is one model).
    let settingsKey: String?
    /// A catalogue entry's ID — the pointer, never the entry's own constant.
    let defaultID: String
    /// A stored ID the catalogue no longer lists is reset to the default at launch
    /// (`normalizeStoredProviders`).
    var normalized = true
}

struct ProviderRoles: OptionSet, Hashable {
    let rawValue: Int
    static let speech = ProviderRoles(rawValue: 1 << 0)
    static let chat = ProviderRoles(rawValue: 1 << 1)
}

/// A provider's API key: where it is kept, where the user gets one, and how setup tells
/// it apart and checks it.
struct APIKeyDescriptor {
    /// Its `SettingsKeys` name: the key's name in `APIKeyStore`, its keychain account,
    /// and the name it had in UserDefaults before it moved.
    let settingsKey: String
    let keysPage: URL
    /// The account has a free plan, so setup's link says "free key".
    let freePlan: Bool
    /// The button on the vendor's page that makes a key.
    let createButton: String
    /// What the vendor's create dialog needs, or the key will not work. Markdown.
    let createNote: String
    /// What every key of this provider begins with.
    let prefix: String
    /// A made-up key of the right shape, for the tests.
    let sample: String
    let verification: KeyVerification
}

/// One light authenticated request: list the models. Nothing is generated or billed.
struct KeyVerification {
    enum Header {
        /// `Authorization: Bearer <key>`.
        case bearer
        /// The key itself in a header of this name.
        case named(String)
    }

    let url: URL
    let header: Header
    /// Further headers the request needs (Anthropic's API version).
    var extraHeaders: [String: String] = [:]
}

// MARK: - Keys

extension Provider {
    /// Whether `text` has the shape of this provider's key. Only for picking a key up off
    /// the clipboard — whether it *works* is `verificationRequest`'s question — so that
    /// whatever else the user copied is never mistaken for one. A key belongs to the
    /// provider with the longest prefix it begins with, so an Anthropic `sk-ant-` key is
    /// not taken for an OpenAI `sk-` one.
    func looksLikeKey(_ text: String) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = descriptor.apiKey?.prefix, key.hasPrefix(prefix) else { return false }
        let claimedByLongerPrefix = Provider.allCases.contains { other in
            guard let otherPrefix = other.descriptor.apiKey?.prefix else { return false }
            return otherPrefix.count > prefix.count && key.hasPrefix(otherPrefix)
        }
        guard !claimedByLongerPrefix else { return false }
        let body = key.dropFirst(prefix.count)
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return body.count >= 20 && body.allSatisfy(allowed)
    }

    /// The key check's request, or nil for a provider with no key.
    func verificationRequest(key: String) -> URLRequest? {
        guard let verification = descriptor.apiKey?.verification else { return nil }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: verification.url)
        switch verification.header {
        case .bearer: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .named(let name): request.setValue(key, forHTTPHeaderField: name)
        }
        for (name, value) in verification.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        return request
    }

    /// Setup's and Settings' link to the key page.
    var linkTitle: String {
        descriptor.apiKey?.freePlan == true ? "Get your free key ↗" : "Get your key ↗"
    }

    /// What a verification answer says about the key.
    ///
    /// A key scoped to less than everything is still a working key: ElevenLabs is told to
    /// give it Speech to Text only, and then refuses the model list with
    /// `missing_permissions`; a restricted OpenAI key answers "insufficient permissions".
    /// Both mean the service knew who was asking, which is all this check is for. A rate
    /// limit means the same. A server error says nothing about the key either way.
    static func verdict(statusCode: Int, body: String) -> KeyVerdict {
        switch statusCode {
        case 200 ..< 300, 429:
            return .valid
        case 401, 403:
            let scoped = ["missing_permissions", "insufficient permissions", "missing scopes"]
            return scoped.contains { body.localizedCaseInsensitiveContains($0) } ? .valid : .invalid
        case 400 ..< 500:
            return .invalid
        default:
            return .unreachable
        }
    }
}
