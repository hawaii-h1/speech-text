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
    /// The languages the user says they speak, as ISO-639-1 codes, in their own order.
    /// Empty when none were named.
    ///
    /// Kept whole alongside `cloudLanguage` because one API takes a *set*: OpenAI's
    /// `gpt-live-transcribe` narrows detection to a list of candidates, where every
    /// other engine here takes a single value or nothing. Defaulted so a configuration
    /// built by hand still describes a valid session.
    var languages: [String] = []
    /// True when no single language was named, so `locale` is a guess — read off the
    /// keyboard layout, or picked from the several languages the user listed — rather
    /// than the one language they said they were speaking. Only a *single* stated
    /// language is ever forced on an engine that can detect one itself.
    let localeIsAutomatic: Bool
    let groqAPIKey: String
    let groqModel: String
    let elevenLabsAPIKey: String
    let elevenLabsModel: String
    /// Shared with the rewrite pass — one OpenAI key, two consumers, as with Groq.
    /// Defaulted so a configuration built by hand (the tests, written before this tier
    /// existed) still describes a valid session.
    var openAIAPIKey: String = ""
    var openAISTTModel: String = defaultOpenAISTTModel
    /// `LocalSTTModel.id`. Defaulted so a configuration built without it (the tests,
    /// written before the local tier existed) still describes a valid session.
    var localModel: String = defaultLocalSTTModel

    /// Drop hesitation sounds, stretched words and trailing-off dots from what the
    /// recogniser returns — see `cleanedTranscript`. `var` with a default so a value
    /// built by hand (the tests) gets the setting's default.
    var removesDisfluencies = true
    /// How the recogniser's em dashes are drawn — see `DashStyle`. Independent of
    /// `removesDisfluencies`: a user who wants every "е-е-е" kept may still not want "—".
    var dashStyle: DashStyle = .default

    /// `cleanedTranscript(text)` when the setting is on, `text` untouched otherwise, with
    /// its dashes in the chosen style either way.
    func cleaned(_ text: String) -> String {
        dashStyle.applied(to: removesDisfluencies ? cleanedTranscript(text) : text)
    }

    /// The language to force on a cloud provider — nil unless the user named exactly one
    /// language, which leaves the model to detect it. Two languages named is still nil:
    /// no provider API takes a set (checked 2026-09-21 — Groq's `language` and
    /// ElevenLabs' `language_code` are single values), and picking one of the two to send
    /// would be the keyboard-layout guess wearing a different hat.
    ///
    /// Whisper and Scribe detect far better than a keyboard layout does:
    /// dictating Ukrainian while the layout was US used to send `language_code=en`, and
    /// a model told the wrong language does not merely mis-spell — it drops most of the
    /// recording and *translates* the rest. Apple is the exception (below): its
    /// recogniser has no auto mode and must be handed a locale.
    var cloudLanguage: String? { localeIsAutomatic ? nil : locale }

    /// What History records as the segment's language: the locale Apple was given, or
    /// "auto" when a cloud model was left to detect it — so a record never claims a
    /// language that was never requested.
    var historyLocale: String { provider == .apple ? locale : (cloudLanguage ?? autoLanguageID) }

    /// True when the selected model is served over a realtime WebSocket rather than an
    /// upload endpoint. Two engines have one; whether live text appears is a function of
    /// the stored *model*, not of the engine.
    var streams: Bool {
        switch provider {
        case .elevenlabs: elevenLabsModel == elevenLabsRealtimeModel
        case .openai: openAISTTModel == openAIRealtimeSTTModel
        case .apple, .groq, .local: false
        }
    }

    /// True when the tier reports text while the user speaks — a realtime stream, or
    /// Apple's on-device recogniser, whose partials arrive as `.live` events too. An
    /// inline dictation shows that text on the overlay; the upload tiers have none to show.
    var hasLiveText: Bool { provider == .apple || streams }

    /// Model ID used for any file upload: the stream's fallback, and History retries.
    /// The realtime model only exists behind the WebSocket, so it maps to scribe_v2;
    /// Apple has no batch API, so an Apple session's upload goes to Groq.
    var batchModel: String {
        switch provider {
        case .elevenlabs: elevenLabsModel == elevenLabsRealtimeModel ? defaultElevenLabsModel : elevenLabsModel
        case .openai: openAISTTModel == openAIRealtimeSTTModel ? defaultOpenAISTTModel : openAISTTModel
        case .groq, .apple: groqModel
        case .local: localModel
        }
    }

    /// Why a file transcription with these settings cannot start, or nil when it can.
    /// History retry asks this instead of testing the key itself: the local tier needs a
    /// model on disk rather than a key, and "add a Groq key" would be the wrong advice.
    /// `modelInstalled` is a parameter so the check stays testable without a filesystem.
    func batchUnavailableReason(modelInstalled: (String) -> Bool = { isLocalModelInstalled($0) }) -> String? {
        switch provider {
        case .local:
            guard !modelInstalled(localModel) else { return nil }
            let name = localSTTModel(id: localModel)?.displayName ?? localModel
            return "\(name) isn't installed — download it in Settings."
        case .elevenlabs:
            return elevenLabsAPIKey.isEmpty ? "Retry needs an ElevenLabs API key — add one in Settings." : nil
        case .openai:
            return openAIAPIKey.isEmpty ? "Retry needs an OpenAI API key — add one in Settings." : nil
        case .groq, .apple:
            return groqAPIKey.isEmpty ? "Retry needs a Groq API key — add one in Settings." : nil
        }
    }

    /// One read of UserDefaults. `locale` defaults to `resolvedLocale()` (keyboard-layout
    /// aware) but callers that already resolved it pass it through.
    static func current(locale: String = resolvedLocale()) -> RecordingConfiguration {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: SettingsKeys.sttProvider) ?? "apple"
        let spoken = storedSpokenLanguages()
        return RecordingConfiguration(
            provider: STTProviderType(rawValue: raw) ?? .apple,
            locale: locale,
            languages: spoken,
            localeIsAutomatic: spoken.count != 1,
            groqAPIKey: defaults.string(forKey: SettingsKeys.groqAPIKey) ?? "",
            groqModel: defaults.string(forKey: SettingsKeys.groqModel) ?? "whisper-large-v3-turbo",
            elevenLabsAPIKey: defaults.string(forKey: SettingsKeys.elevenLabsAPIKey) ?? "",
            elevenLabsModel: defaults.string(forKey: SettingsKeys.elevenLabsModel) ?? defaultElevenLabsModel,
            openAIAPIKey: defaults.string(forKey: SettingsKeys.openAIAPIKey) ?? "",
            openAISTTModel: defaults.string(forKey: SettingsKeys.openAISTTModel) ?? defaultOpenAISTTModel,
            localModel: defaults.string(forKey: SettingsKeys.localSTTModel) ?? defaultLocalSTTModel,
            removesDisfluencies: defaults.object(forKey: SettingsKeys.removeDisfluencies) as? Bool ?? true,
            dashStyle: .current
        )
    }
}
