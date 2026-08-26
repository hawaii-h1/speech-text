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

    // Launch at Login
    static let hasRegisteredLaunchAtLogin = "hasRegisteredLaunchAtLogin"

    // Debug
    static let debugMode = "debugMode"
}

let groqModels: [(id: String, name: String)] = [
    ("whisper-large-v3-turbo", "Whisper Large V3 Turbo"),
    ("whisper-large-v3", "Whisper Large V3"),
]

let elevenLabsModels: [(id: String, name: String)] = [
    ("scribe_v1", "Scribe v1"),
    ("scribe_v1_experimental", "Scribe v1 Experimental"),
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
