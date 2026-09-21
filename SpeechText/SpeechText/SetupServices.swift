// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - First run

/// The steps of the setup window, in order. The raw values are what `onboardingStep`
/// stores, so a window closed half-way opens where it was left.
enum OnboardingStep: String, CaseIterable, Comparable {
    case welcome
    case speech
    case ai
    case permissions
    case tryIt = "try"
    case done

    /// The five the step bar names; Done is the Try it step's second state, not a stop.
    static let named: [OnboardingStep] = [.welcome, .speech, .ai, .permissions, .tryIt]

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .speech: "Speech"
        case .ai: "AI"
        case .permissions: "Permissions"
        case .tryIt, .done: "Try it"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.index < rhs.index }
}

/// Whether the setup window opens at launch.
///
/// Only new users see it. There was no first-run marker before it existed, so an install
/// that predates it is recognised by what it already stored: a login-item registration,
/// or any setting that crosses a rename (which is also how a renamed install is caught,
/// once `adoptPreRenameDefaults()` has carried its settings over). Such a user is marked
/// done and never shown a flow for a setup they finished long ago.
enum OnboardingGate: Equatable {
    case show
    /// An existing install: record setup as done, show nothing.
    case markCompleted
    case skip

    static func decide(completed: Bool?, hasUsedTheAppBefore: Bool) -> OnboardingGate {
        switch completed {
        case true?: .skip
        case false?: .show
        case nil: hasUsedTheAppBefore ? .markCompleted : .show
        }
    }
}

// MARK: - Services and their keys

/// An online service setup can connect, and everything the key block says about it.
/// Checked against each vendor's key page on 2026-09-19.
enum SetupService: String, CaseIterable, Identifiable {
    case groq
    case elevenLabs
    case anthropic
    case openAI

    var id: String { rawValue }

    /// The name the user knows the product by.
    var name: String {
        switch self {
        case .groq: "Groq"
        case .elevenLabs: "ElevenLabs"
        case .anthropic: "Claude"
        case .openAI: "ChatGPT"
        }
    }

    /// The company whose account the key belongs to.
    var account: String {
        switch self {
        case .groq: "Groq"
        case .elevenLabs: "ElevenLabs"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    var keysPage: URL {
        switch self {
        case .groq: URL(string: "https://console.groq.com/keys")!
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/developers/api-keys")!
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    var linkTitle: String { self == .groq ? "Get your free key ↗" : "Get your key ↗" }

    /// The button on the vendor's page that makes a key.
    var createButton: String {
        switch self {
        case .groq: "Create API Key"
        case .elevenLabs: "Create Key"
        case .anthropic: "Create key"
        case .openAI: "Create new secret key"
        }
    }

    /// What the vendor's create dialog needs, or the key will not work. Markdown.
    var createNote: String {
        switch self {
        case .groq: "Copy the key."
        case .elevenLabs: "Give it **Speech to Text** access, then copy the key."
        case .anthropic: "Pick a workspace, set expiry to **Never**, then copy the key."
        case .openAI: "Keep permissions on **All**, then copy the key. Needs credit in Billing."
        }
    }

    /// Where the app keeps this key. Groq's serves speech and AI alike.
    var settingsKey: String {
        switch self {
        case .groq: SettingsKeys.groqAPIKey
        case .elevenLabs: SettingsKeys.elevenLabsAPIKey
        case .anthropic: SettingsKeys.anthropicAPIKey
        case .openAI: SettingsKeys.openAIAPIKey
        }
    }

    /// Whether `text` has the shape of this service's key. Only for picking a key up off
    /// the clipboard — whether it *works* is `verificationRequest`'s question — so that
    /// whatever else the user copied is never mistaken for one.
    func looksLikeKey(_ text: String) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        switch self {
        case .groq: prefix = "gsk_"
        case .elevenLabs: prefix = "sk_"
        case .anthropic: prefix = "sk-ant-"
        case .openAI:
            guard !key.hasPrefix("sk-ant-") else { return false }
            prefix = "sk-"
        }
        guard key.hasPrefix(prefix) else { return false }
        let body = key.dropFirst(prefix.count)
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return body.count >= 20 && body.allSatisfy(allowed)
    }

    /// One light authenticated request: list the models. Nothing is generated or billed.
    func verificationRequest(key: String) -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var request: URLRequest
        switch self {
        case .groq:
            request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .elevenLabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        return request
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

enum KeyVerdict: Equatable {
    case valid
    case invalid
    /// No answer about the key: offline, or the service is down. The user may go on.
    case unreachable
}
