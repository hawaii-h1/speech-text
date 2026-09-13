import Foundation

enum SettingsKeys {
    static let webhookURL = "webhookURL"
    static let authToken = "authToken"
    static let selectedLanguage = "selectedLanguage"

    // STT Provider
    static let sttProvider = "sttProvider"
    static let groqAPIKey = "groqAPIKey"
    static let groqModel = "groqModel"
    static let elevenLabsAPIKey = "elevenLabsAPIKey"
    static let elevenLabsModel = "elevenLabsModel"

    // Hotkey (inline recording)
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifierFlags = "hotkeyModifierFlags"

    // Hotkey (record window)
    static let recordWindowHotkeyKeyCode = "recordWindowHotkeyKeyCode"
    static let recordWindowHotkeyModifierFlags = "recordWindowHotkeyModifierFlags"

    // Hotkey (AI recording — transcription is post-processed by an LLM)
    static let aiHotkeyKeyCode = "aiHotkeyKeyCode"
    static let aiHotkeyModifierFlags = "aiHotkeyModifierFlags"

    // LLM post-processing
    static let llmProvider = "llmProvider"
    static let groqLLMModel = "groqLLMModel"
    static let anthropicAPIKey = "anthropicAPIKey"
    static let anthropicModel = "anthropicModel"
    static let openAIAPIKey = "openAIAPIKey"
    static let openAIModel = "openAIModel"
    /// JSON-encoded `[PromptPreset]`.
    static let promptPresets = "promptPresets"
    /// UUID string of the preset used when no other preset matches.
    static let defaultPresetID = "defaultPresetID"
    /// Whether the Record Window's ✨ toggle is on.
    static let aiModeInRecordWindow = "aiModeInRecordWindow"

    // Message delivery
    /// Whether an AI dictation may be routed to a messaging app instead of the cursor.
    static let messageSendingEnabled = "messageSendingEnabled"

    // Launch at Login
    static let hasRegisteredLaunchAtLogin = "hasRegisteredLaunchAtLogin"

    /// Bumped when the built-in hotkey layout changes, so stored shortcuts can be
    /// migrated once instead of silently keeping the old assignment.
    static let hotkeyLayoutVersion = "hotkeyLayoutVersion"

    // Appearance
    /// `AppSkin.rawValue`.
    static let appSkin = "appSkin"
    /// `#RRGGBB` — only the minimal skin uses it.
    static let accentColor = "accentColor"

    // Debug
    static let debugMode = "debugMode"

    /// Marks that settings were carried over from the pre-rename preference domain.
    static let didAdoptPreRenameDefaults = "didAdoptPreRenameDefaults"

    /// Everything worth carrying across a rename.
    ///
    /// Deliberately not the whole domain: `hasRegisteredLaunchAtLogin` and the
    /// accessibility prompt flag describe grants made to the *old* bundle identifier,
    /// and copying them would leave the new app unregistered and unprompted.
    static let portable: [String] = [
        webhookURL, authToken, selectedLanguage,
        sttProvider, groqAPIKey, groqModel, elevenLabsAPIKey, elevenLabsModel,
        hotkeyKeyCode, hotkeyModifierFlags,
        recordWindowHotkeyKeyCode, recordWindowHotkeyModifierFlags,
        aiHotkeyKeyCode, aiHotkeyModifierFlags,
        llmProvider, groqLLMModel, anthropicAPIKey, anthropicModel,
        openAIAPIKey, openAIModel,
        promptPresets, defaultPresetID, aiModeInRecordWindow,
        messageSendingEnabled,
        appSkin, accentColor,
        hotkeyLayoutVersion, debugMode,
    ]
}

/// The app shipped as VoicePeter under `com.voicepeter.app`. Preferences are keyed by
/// bundle identifier, so after the rename every setting — API keys, shortcuts and
/// prompt presets included — would read as empty and look exactly like a factory
/// reset. Copy them across once.
///
/// Runs before `normalizeStoredProviders()` so anything stale that comes over is
/// still checked against the current catalogues.
func adoptPreRenameDefaults() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: SettingsKeys.didAdoptPreRenameDefaults) else { return }
    defaults.set(true, forKey: SettingsKeys.didAdoptPreRenameDefaults)

    guard let legacy = UserDefaults(suiteName: "com.voicepeter.app") else { return }
    var adopted = 0
    for key in SettingsKeys.portable {
        // Never clobber a value the user has already set under the new name.
        guard defaults.object(forKey: key) == nil,
              let value = legacy.object(forKey: key) else { continue }
        defaults.set(value, forKey: key)
        adopted += 1
    }
    if adopted > 0 {
        dlog("Settings", "carried \(adopted) setting(s) over from the VoicePeter preferences")
    }
}

let groqModels: [(id: String, name: String)] = [
    ("whisper-large-v3-turbo", "Whisper Large V3 Turbo"),
    ("whisper-large-v3", "Whisper Large V3"),
]

/// Scribe's streaming model. Picking it switches ElevenLabs from a file upload after
/// the recording to a WebSocket that returns text while the user is still speaking.
let elevenLabsRealtimeModel = "scribe_v2_realtime"

/// The batch (upload) model IDs are exactly what the API's `unsupported_model` error
/// lists — scribe_v1, scribe_v1_experimental, scribe_v2 — plus the realtime model, which
/// only exists behind the WebSocket.
let elevenLabsModels: [(id: String, name: String)] = [
    ("scribe_v1", "Scribe v1"),
    ("scribe_v1_experimental", "Scribe v1 Experimental"),
    ("scribe_v2", "Scribe v2"),
    (elevenLabsRealtimeModel, "Scribe v2 Realtime — live text"),
]

struct SupportedLanguage: Identifiable, Hashable {
    let id: String
    let displayName: String
    let localeIdentifier: String
}

/// Special value meaning "use the macOS system language".
let autoLanguageID = "auto"

let supportedLanguages: [SupportedLanguage] = [
    SupportedLanguage(id: autoLanguageID, displayName: "Auto (System)", localeIdentifier: autoLanguageID),
    SupportedLanguage(id: "en-US", displayName: "English (US)", localeIdentifier: "en-US"),
    SupportedLanguage(id: "uk-UA", displayName: "Ukrainian", localeIdentifier: "uk-UA"),
]

/// Map of macOS keyboard layout names → ISO 639-1 language codes.
/// Layout names come from `com.apple.HIToolbox` AppleSelectedInputSources.
private let layoutToLanguage: [String: String] = [
    "US": "en", "USInternational-PC": "en", "ABC": "en",
    "British": "en", "Australian": "en", "Canadian": "en",
    "Ukrainian": "uk", "Ukrainian-PC": "uk",
    "Russian": "ru", "Russian-Phonetic": "ru", "RussianWin": "ru",
    "Spanish": "es", "Spanish - ISO": "es",
    "French": "fr", "French-PC": "fr", "Canadian-CSA": "fr",
    "German": "de", "German-DIN-2137": "de",
    "Italian": "it",
    "Portuguese": "pt", "Brazilian": "pt",
    "Dutch": "nl",
    "Polish": "pl", "PolishPro": "pl",
    "Czech": "cs", "Czech-QWERTY": "cs",
    "Japanese": "ja", "Turkish": "tr", "Korean": "ko",
    "Swedish": "sv", "Norwegian": "no", "Danish": "da", "Finnish": "fi",
    "Colemak": "en", "Dvorak": "en", "DVORAK-QWERTYCMD": "en",
]

/// Returns the language of the currently active keyboard input source.
/// Reads from `com.apple.HIToolbox` preferences (pure Foundation, no Carbon).
private func currentInputSourceLanguage() -> String? {
    guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else { return nil }
    defaults.synchronize()

    if let sourceID = defaults.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID") {
        let layoutName = sourceID.replacingOccurrences(of: "com.apple.keylayout.", with: "")
        if let lang = layoutToLanguage[layoutName] { return lang }
    }

    if let sources = defaults.object(forKey: "AppleSelectedInputSources") as? [[String: Any]] {
        for source in sources {
            if let name = source["KeyboardLayout Name"] as? String,
               let lang = layoutToLanguage[name] {
                return lang
            }
        }
    }

    return nil
}

/// Drops provider settings whose stored value no longer maps to a known case.
///
/// A stale identifier is worse than a missing one: the picker in Settings finds no
/// matching tag and renders blank, while the engine quietly falls back to its
/// default — so the UI shows nothing and the app runs something the user did not pick.
func normalizeStoredProviders() {
    let defaults = UserDefaults.standard

    if let raw = defaults.string(forKey: SettingsKeys.sttProvider),
       STTProviderType(rawValue: raw) == nil {
        dlog("Settings", "sttProvider=\"\(raw)\" is not a known engine — resetting to Apple")
        defaults.set(STTProviderType.apple.rawValue, forKey: SettingsKeys.sttProvider)
    }

    if let raw = defaults.string(forKey: SettingsKeys.llmProvider),
       LLMProviderType(rawValue: raw) == nil {
        dlog("Settings", "llmProvider=\"\(raw)\" is not a known provider — resetting to Groq")
        defaults.set(LLMProviderType.groq.rawValue, forKey: SettingsKeys.llmProvider)
    }

    // Model catalogues get replaced when a vendor retires a generation; a stored ID
    // that is no longer offered blanks the picker exactly like a stale provider does.
    normalizeStoredModel(SettingsKeys.groqModel, in: groqModels, fallback: "whisper-large-v3-turbo")
    normalizeStoredModel(SettingsKeys.elevenLabsModel, in: elevenLabsModels, fallback: "scribe_v1")
    normalizeStoredModel(SettingsKeys.groqLLMModel, in: groqChatModels, fallback: defaultGroqLLMModel)
    normalizeStoredModel(SettingsKeys.anthropicModel, in: anthropicChatModels, fallback: defaultAnthropicModel)
    normalizeStoredModel(SettingsKeys.openAIModel, in: openAIChatModels, fallback: defaultOpenAIModel)
}

private func normalizeStoredModel(
    _ key: String,
    in catalog: [(id: String, name: String)],
    fallback: String
) {
    let defaults = UserDefaults.standard
    guard let raw = defaults.string(forKey: key),
          !catalog.contains(where: { $0.id == raw })
    else { return }
    dlog("Settings", "\(key)=\"\(raw)\" is no longer offered — resetting to \(fallback)")
    defaults.set(fallback, forKey: key)
}

/// Resolves the effective locale identifier for speech recognition.
/// When set to "auto", reads the active keyboard input source so the language
/// follows whichever keyboard the user has switched to.
func resolvedLocale() -> String {
    let stored = UserDefaults.standard.string(forKey: SettingsKeys.selectedLanguage) ?? autoLanguageID
    if stored == autoLanguageID {
        return currentInputSourceLanguage()
            ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }
    return stored
}

// MARK: - Keyboard Change Observer

/// Observes keyboard input source changes using .deliverImmediately so
/// notifications arrive even when the app is in the background.
final class KeyboardChangeObserver: NSObject {
    static let shared = KeyboardChangeObserver()

    private var handlers: [(id: UUID, block: () -> Void)] = []

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(keyboardDidChange),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func keyboardDidChange() {
        handlers.forEach { $0.block() }
    }

    func addHandler(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        handlers.append((id: id, block: block))
        return id
    }

    func removeHandler(id: UUID) {
        handlers.removeAll { $0.id == id }
    }
}
