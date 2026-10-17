// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the app and the SpeechTextLLM service say to each other. The service runs
/// llama.cpp in its own process (`Contents/XPCServices/SpeechTextLLM.xpc`), so a crash in
/// it or a model that exhausts memory ends the service, not the dictation: the app sees an
/// interrupted connection, AI Rewrite falls back to the transcript as for any failed
/// rewrite, and launchd starts the service again for the next request.
///
/// Requests and replies cross as JSON (`Data`), so the protocol needs no `NSSecureCoding`
/// classes and both sides decode the same `Codable` types.
let localChatServiceName = "app.speech-text.SpeechText.LLM"

@objc protocol LocalChatServiceProtocol {
    /// Loads the model if it is not already the one in memory, then answers. `reply` gets
    /// a JSON `LocalChatResponse`, or nil and the error's message.
    func complete(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    /// Loads the model ahead of the first request — a cold load takes seconds — and reads
    /// the request's `prefixes`, the system prompts, which take seconds more.
    func prewarm(_ request: Data, reply: @escaping (String?) -> Void)
    /// Stops a running completion at its next token.
    func cancel()
    /// Drops the model from memory (a removed download, or the user switched away).
    func unload(reply: @escaping () -> Void)
}

struct LocalChatRequest: Codable, Equatable {
    var modelPath: String
    var family: ChatTemplateFamily
    var system: String
    var user: String
    var maxTokens: Int
    var contextLength: Int
    /// For a prewarm: system prompts to read ahead, so the requests that follow restore
    /// them (AI dictation's and the Edit shortcut's). Nil on a completion.
    var prefixes: [String]? = nil
}

struct LocalChatResponse: Codable, Equatable {
    var reply: String
    var promptTokens: Int
    var outputTokens: Int
    var loadSeconds: Double
    var promptSeconds: Double
    var generationSeconds: Double
    var finished: Bool
}
