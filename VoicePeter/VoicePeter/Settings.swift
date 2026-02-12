import Foundation

enum SettingsKeys {
    static let webhookURL = "webhookURL"
    static let authToken = "authToken"
    static let selectedLanguage = "selectedLanguage"

    // STT Provider
    static let sttProvider = "sttProvider"
    static let groqAPIKey = "groqAPIKey"
    static let groqModel = "groqModel"

    // Hotkey (inline recording)
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifierFlags = "hotkeyModifierFlags"

    // Hotkey (record window)
    static let recordWindowHotkeyKeyCode = "recordWindowHotkeyKeyCode"
    static let recordWindowHotkeyModifierFlags = "recordWindowHotkeyModifierFlags"
}

let groqModels: [(id: String, name: String)] = [
    ("whisper-large-v3-turbo", "Whisper Large V3 Turbo"),
    ("whisper-large-v3", "Whisper Large V3"),
]

struct SupportedLanguage: Identifiable, Hashable {
    let id: String
    let displayName: String
    let localeIdentifier: String
}

let supportedLanguages: [SupportedLanguage] = [
    SupportedLanguage(id: "en-US", displayName: "English (US)", localeIdentifier: "en-US"),
    SupportedLanguage(id: "uk-UA", displayName: "Ukrainian", localeIdentifier: "uk-UA"),
]
