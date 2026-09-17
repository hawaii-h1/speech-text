// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Everything the engine and the provider factories need for one recording session,
/// read from UserDefaults exactly once (`current()`) and carried through the session.
/// Settings changed mid-recording must not affect the running session — a picker
/// change while the mic was live used to switch the provider between pause and stop.
struct RecordingConfiguration {
    let provider: STTProviderType
    /// The recognition locale, always a concrete identifier. `var` because
    /// `SpeechEngine.resumeRecording(locale:)` follows the keyboard layout across
    /// segments; everything else is fixed for the session.
    var locale: String
    /// True when the user left Language on "Auto (System)", so `locale` is a guess read
    /// off the keyboard layout rather than something they chose.
    let localeIsAutomatic: Bool
    let groqAPIKey: String
    let groqModel: String
    let elevenLabsAPIKey: String
    let elevenLabsModel: String
    /// `LocalSTTModel.id`. Defaulted so a configuration built without it (the tests,
    /// written before the local tier existed) still describes a valid session.
    var localModel: String = defaultLocalSTTModel

    /// The language to force on a cloud provider — nil on Auto, which leaves the model
    /// to detect it. Whisper and Scribe do that far better than a keyboard layout does:
    /// dictating Ukrainian while the layout was US used to send `language_code=en`, and
    /// a model told the wrong language does not merely mis-spell — it drops most of the
    /// recording and *translates* the rest. Apple is the exception (below): its
    /// recogniser has no auto mode and must be handed a locale.
    var cloudLanguage: String? { localeIsAutomatic ? nil : locale }

    /// What History records as the segment's language: the locale Apple was given, or
    /// "auto" when a cloud model was left to detect it — so a record never claims a
    /// language that was never requested.
    var historyLocale: String { provider == .apple ? locale : (cloudLanguage ?? autoLanguageID) }

    /// True when the selected model is served over the realtime WebSocket.
    var streams: Bool { provider == .elevenlabs && elevenLabsModel == elevenLabsRealtimeModel }

    /// Model ID used for any file upload: the stream's fallback, and History retries.
    /// The realtime model only exists behind the WebSocket, so it maps to scribe_v2;
    /// Apple has no batch API, so an Apple session's upload goes to Groq.
    var batchModel: String {
        switch provider {
        case .elevenlabs: elevenLabsModel == elevenLabsRealtimeModel ? defaultElevenLabsModel : elevenLabsModel
        case .groq, .apple: groqModel
        case .local: localModel
        }
    }

    /// The key the batch (upload) path will use. Empty for the local tier, which has none.
    var batchAPIKey: String {
        switch provider {
        case .elevenlabs: elevenLabsAPIKey
        case .groq, .apple: groqAPIKey
        case .local: ""
        }
    }

    /// Why a file transcription with these settings cannot start, or nil when it can.
    /// History retry asks this instead of testing the key itself: the local tier needs a
    /// model on disk rather than a key, and "add a Groq key" would be the wrong advice.
    /// `modelInstalled` is a parameter so the check stays testable without a filesystem.
    func batchUnavailableReason(modelInstalled: (String) -> Bool = isLocalModelInstalled) -> String? {
        switch provider {
        case .local:
            guard !modelInstalled(localModel) else { return nil }
            let name = localSTTModel(id: localModel)?.displayName ?? localModel
            return "\(name) isn't installed — download it in Settings."
        case .elevenlabs:
            return elevenLabsAPIKey.isEmpty ? "Retry needs an ElevenLabs API key — add one in Settings." : nil
        case .groq, .apple:
            return groqAPIKey.isEmpty ? "Retry needs a Groq API key — add one in Settings." : nil
        }
    }

    /// One read of UserDefaults. `locale` defaults to `resolvedLocale()` (keyboard-layout
    /// aware) but callers that already resolved it pass it through.
    static func current(locale: String = resolvedLocale()) -> RecordingConfiguration {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: SettingsKeys.sttProvider) ?? "apple"
        let language = defaults.string(forKey: SettingsKeys.selectedLanguage) ?? autoLanguageID
        return RecordingConfiguration(
            provider: STTProviderType(rawValue: raw) ?? .apple,
            locale: locale,
            localeIsAutomatic: language == autoLanguageID,
            groqAPIKey: defaults.string(forKey: SettingsKeys.groqAPIKey) ?? "",
            groqModel: defaults.string(forKey: SettingsKeys.groqModel) ?? "whisper-large-v3-turbo",
            elevenLabsAPIKey: defaults.string(forKey: SettingsKeys.elevenLabsAPIKey) ?? "",
            elevenLabsModel: defaults.string(forKey: SettingsKeys.elevenLabsModel) ?? defaultElevenLabsModel,
            localModel: defaults.string(forKey: SettingsKeys.localSTTModel) ?? defaultLocalSTTModel
        )
    }
}
