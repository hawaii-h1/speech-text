import Foundation

/// Everything the engine and the provider factories need for one recording session,
/// read from UserDefaults exactly once (`current()`) and carried through the session.
/// Settings changed mid-recording must not affect the running session — a picker
/// change while the mic was live used to switch the provider between pause and stop.
struct RecordingConfiguration {
    let provider: STTProviderType
    /// The recognition locale. `var` because `SpeechEngine.resumeRecording(locale:)`
    /// follows the keyboard layout across segments; everything else is fixed for the session.
    var locale: String
    let groqAPIKey: String
    let groqModel: String
    let elevenLabsAPIKey: String
    let elevenLabsModel: String

    /// True when the selected model is served over the realtime WebSocket.
    var streams: Bool { provider == .elevenlabs && elevenLabsModel == elevenLabsRealtimeModel }

    /// Model ID used for any file upload: the stream's fallback, and History retries.
    /// The realtime model only exists behind the WebSocket, so it maps to scribe_v1;
    /// Apple has no batch API, so an Apple session's upload goes to Groq.
    var batchModel: String {
        switch provider {
        case .elevenlabs: elevenLabsModel == elevenLabsRealtimeModel ? "scribe_v1" : elevenLabsModel
        case .groq, .apple: groqModel
        }
    }

    /// The key the batch (upload) path will use. History retry checks it before starting.
    var batchAPIKey: String { provider == .elevenlabs ? elevenLabsAPIKey : groqAPIKey }

    /// One read of UserDefaults. `locale` defaults to `resolvedLocale()` (keyboard-layout
    /// aware) but callers that already resolved it pass it through.
    static func current(locale: String = resolvedLocale()) -> RecordingConfiguration {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: SettingsKeys.sttProvider) ?? "apple"
        return RecordingConfiguration(
            provider: STTProviderType(rawValue: raw) ?? .apple,
            locale: locale,
            groqAPIKey: defaults.string(forKey: SettingsKeys.groqAPIKey) ?? "",
            groqModel: defaults.string(forKey: SettingsKeys.groqModel) ?? "whisper-large-v3-turbo",
            elevenLabsAPIKey: defaults.string(forKey: SettingsKeys.elevenLabsAPIKey) ?? "",
            elevenLabsModel: defaults.string(forKey: SettingsKeys.elevenLabsModel) ?? "scribe_v1"
        )
    }
}
