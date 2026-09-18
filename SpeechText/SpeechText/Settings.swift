// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SettingsKeys {
    static let selectedLanguage = "selectedLanguage"

    // STT Provider
    static let sttProvider = "sttProvider"
    static let groqAPIKey = "groqAPIKey"
    static let groqModel = "groqModel"
    static let elevenLabsAPIKey = "elevenLabsAPIKey"
    static let elevenLabsModel = "elevenLabsModel"
    /// `LocalSTTModel.id` (a WhisperKit variant) the local engine transcribes with.
    static let localSTTModel = "localSTTModel"
    /// Whether "е-е-е", "тооо" and trailing "..." are cleaned out of transcripts.
    static let removeDisfluencies = "removeDisfluencies"
    /// `DashStyle.rawValue`: how em dashes in transcripts and AI output are drawn.
    static let dashStyle = "dashStyle"

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
    /// Ollama tag for the local rewrite pass — any model the daemon has, not only the
    /// catalogue's, so it is deliberately not normalised against `localLLMModels`.
    static let ollamaModel = "ollamaModel"
    /// Ollama's base URL; empty means `ollamaDefaultBaseURL`.
    static let ollamaBaseURL = "ollamaBaseURL"
    /// JSON-encoded `[PromptPreset]`.
    static let promptPresets = "promptPresets"
    /// UUID string of the preset used when no other preset matches.
    static let defaultPresetID = "defaultPresetID"
    /// Whether the Record Window's ✨ toggle is on.
    static let aiModeInRecordWindow = "aiModeInRecordWindow"
    /// Whether an AI dictation shows its raw text while the user speaks, replaced by the
    /// rewrite at the stop. Tier A only; off by default.
    static let aiDraftWhileSpeaking = "aiDraftWhileSpeaking"
    /// Whether an AI dictation tells the model which app, window and field it is for.

    // Launch at Login
    static let hasRegisteredLaunchAtLogin = "hasRegisteredLaunchAtLogin"

    /// Whether holding a dictation shortcut records until it is let go. A quick tap still
    /// toggles, so this only adds the hold. Off by default.
    static let holdToTalk = "holdToTalk"

    /// Bumped when the built-in hotkey layout changes, so stored shortcuts can be
    /// migrated once instead of silently keeping the old assignment.
    static let hotkeyLayoutVersion = "hotkeyLayoutVersion"

    // Appearance
    /// `AppSkin.rawValue`.
    static let appSkin = "appSkin"
    /// `#RRGGBB` — only the minimal skin uses it.
    static let accentColor = "accentColor"
    /// `DockIconMode.rawValue`: never, while a window is open, or always.
    static let dockIconMode = "dockIconMode"
    /// Where the user dragged the inline overlay: its bottom-left corner as `"x,y"` in
    /// screen coordinates (UserDefaults has no point type). Empty means the default
    /// corner. Monitor geometry, so machine-local and not in `portable`.
    static let overlayOrigin = "overlayOrigin"

    // Debug
    /// Whether inline dictations are written to `Traces/` for `DictationReplay`. Machine-
    /// local, like the traces themselves, so not in `portable`.
    static let recordDictationTraces = "recordDictationTraces"

    /// Marks that settings were carried over from the pre-rename preference domain.
    static let didAdoptPreRenameDefaults = "didAdoptPreRenameDefaults"

    /// Everything worth carrying across a rename.
    ///
    /// Deliberately not the whole domain: `hasRegisteredLaunchAtLogin` and the
    /// accessibility prompt flag describe grants made to the *old* bundle identifier,
    /// and copying them would leave the new app unregistered and unprompted.
    ///
    /// Sparkle's own keys (`SUEnableAutomaticChecks`, `SULastCheckTime`,
    /// `SUSkippedVersion`) are missing for the same reason, and should stay missing: a
    /// new identity re-defaults to checking for updates, whereas a carried-over
    /// `SUSkippedVersion` would suppress an update the new install never saw offered.
    static let portable: [String] = [
        selectedLanguage,
        sttProvider, groqAPIKey, groqModel, elevenLabsAPIKey, elevenLabsModel, localSTTModel,
        removeDisfluencies, dashStyle,
        hotkeyKeyCode, hotkeyModifierFlags,
        recordWindowHotkeyKeyCode, recordWindowHotkeyModifierFlags,
        aiHotkeyKeyCode, aiHotkeyModifierFlags,
        llmProvider, groqLLMModel, anthropicAPIKey, anthropicModel,
        openAIAPIKey, openAIModel, ollamaModel, ollamaBaseURL,
        promptPresets, defaultPresetID, aiModeInRecordWindow,
        appSkin, accentColor, dockIconMode,
        hotkeyLayoutVersion,
    ]
}

/// Preference domains this app has run under before, newest first.
///
/// `com.voicepeter.app` is the original name; `com.speachtext.app` is the rename that
/// shipped the typo the product name no longer has. Newest first matters: a machine
/// that saw both should take the *later* value, and the loop below never overwrites a
/// key it has already adopted.
private let preRenameDefaultsDomains = ["com.speachtext.app", "com.voicepeter.app"]

/// Preferences are keyed by bundle identifier, so each rename leaves every setting —
/// API keys, shortcuts and prompt presets included — reading as empty, which looks
/// exactly like a factory reset. Copy them across once.
///
/// Runs before `normalizeStoredProviders()` so anything stale that comes over is
/// still checked against the current catalogues.
func adoptPreRenameDefaults() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: SettingsKeys.didAdoptPreRenameDefaults) else { return }
    defaults.set(true, forKey: SettingsKeys.didAdoptPreRenameDefaults)

    for domain in preRenameDefaultsDomains {
        guard let legacy = UserDefaults(suiteName: domain) else { continue }
        var adopted = 0
        for key in SettingsKeys.portable {
            // Never clobber a value already set under the new name, or adopted from a
            // newer domain on an earlier pass.
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            adopted += 1
        }
        if adopted > 0 {
            dlog("Settings", "carried \(adopted) setting(s) over from the \(domain) preferences")
        }
    }
}

let groqModels: [(id: String, name: String)] = [
    ("whisper-large-v3-turbo", "Whisper Large V3 Turbo"),
    ("whisper-large-v3", "Whisper Large V3"),
]

/// Scribe's streaming model. Picking it switches ElevenLabs from a file upload after
/// the recording to a WebSocket that returns text while the user is still speaking.
let elevenLabsRealtimeModel = "scribe_v2_realtime"

/// The batch model: the default, the stream's fallback and History retries.
let defaultElevenLabsModel = "scribe_v2"

/// The batch (upload) model IDs are exactly what the API's `unsupported_model` error
/// lists, minus the two that are gone: scribe_v1 is deprecated in favour of scribe_v2 and
/// scribe_v1_experimental no longer appears in the documentation (checked 2026-09-16) —
/// stored values for either are normalised to scribe_v2. Plus the realtime model, which
/// only exists behind the WebSocket.
let elevenLabsModels: [(id: String, name: String)] = [
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

    // Settings for removed features: the webhook (whose bearer token should not outlive
    // it) and the switch that used to keep the focus context out of AI dictations.
    for key in ["webhookURL", "authToken", "aiFocusContextEnabled"] {
        defaults.removeObject(forKey: key)
    }

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
    normalizeStoredModel(SettingsKeys.elevenLabsModel, in: elevenLabsModels, fallback: defaultElevenLabsModel)
    normalizeStoredModel(SettingsKeys.groqLLMModel, in: groqChatModels, fallback: defaultGroqLLMModel)
    normalizeStoredModel(SettingsKeys.anthropicModel, in: anthropicChatModels, fallback: defaultAnthropicModel)
    normalizeStoredModel(SettingsKeys.openAIModel, in: openAIChatModels, fallback: defaultOpenAIModel)
    normalizeStoredModel(SettingsKeys.localSTTModel,
                         in: localSTTModels.map { (id: $0.id, name: $0.displayName) },
                         fallback: defaultLocalSTTModel)
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
