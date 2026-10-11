// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What `scripts/e2e.sh` changes in a debug build, read from launch arguments (the
/// argument domain, so nothing here is ever written to the app's preferences). A
/// Release build compiles none of it: `isActive` is false and every input is nil.
///
/// - `-SPTAudioInput a.wav,b.wav` — every capture start (`SpeechEngine.makeCapture`)
///   plays the next file instead of opening a microphone; see `FileCapture`.
/// - `-SPTKeysFile <path>` — API keys for this session only, in the env-file shape
///   `LiveProviderTests` reads (`GROQ_API_KEY=…`). Never written anywhere: the installed
///   keychain build takes a key in its preferences domain for a newer one and would
///   replace the user's own with it.
/// - The bundle identifier `app.speech-text.SpeechText.e2e`, which the script stamps on
///   its build: its own preferences domain and its own data folder
///   (`Application Support/SpeechText-e2e`), so a run never reaches the user's settings,
///   History or traces, and no rename migration copies anything into it.
enum E2EMode {
    static let bundleIdentifier = "app.speech-text.SpeechText.e2e"

    /// The env-file names, as `LiveProviderTests` reads them from the environment.
    static let keyNames: [String: String] = [
        "GROQ_API_KEY": SettingsKeys.groqAPIKey,
        "OPENAI_API_KEY": SettingsKeys.openAIAPIKey,
        "ELEVENLABS_API_KEY": SettingsKeys.elevenLabsAPIKey,
        "ANTHROPIC_API_KEY": SettingsKeys.anthropicAPIKey,
    ]

    /// `NAME=value` lines (an `export ` prefix, quotes, blank lines and `#` comments
    /// allowed) mapped onto the `SettingsKeys` the store holds; unknown names are left out.
    static func parseKeys(_ text: String) -> [String: String] {
        var keys: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if let key = keyNames[name], !value.isEmpty { keys[key] = value }
        }
        return keys
    }

    #if DEBUG
    static var isActive: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }

    /// The clips `-SPTAudioInput` names, in order; nil when the argument is absent.
    static let audioInputs: [URL]? = UserDefaults.standard.string(forKey: "SPTAudioInput").map { list in
        list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    static let keysFile: URL? = UserDefaults.standard.string(forKey: "SPTKeysFile")
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    private static let lock = NSLock()
    private static var playedInputs = 0

    /// The clip for the next capture, or nil once every one has played — that capture
    /// records silence, as a microphone in a quiet room would.
    static func nextAudioInput() -> URL? {
        guard let inputs = audioInputs else { return nil }
        return lock.withLock {
            defer { playedInputs += 1 }
            return playedInputs < inputs.count ? inputs[playedInputs] : nil
        }
    }
    #else
    static let isActive = false
    static let audioInputs: [URL]? = nil
    static let keysFile: URL? = nil
    #endif

    /// The folder in Application Support this build keeps History, recordings and
    /// traces in.
    static var supportFolderName: String { isActive ? "SpeechText-e2e" : "SpeechText" }
}
