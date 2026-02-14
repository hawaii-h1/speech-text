import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.webhookURL) private var webhookURL = ""
    @AppStorage(SettingsKeys.authToken) private var authToken = ""
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = "en-US"
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = "apple"
    @AppStorage(SettingsKeys.groqAPIKey) private var groqAPIKey = ""
    @AppStorage(SettingsKeys.groqModel) private var groqModel = "whisper-large-v3-turbo"

    var body: some View {
        Form {
            Section("STT Provider") {
                Picker("Provider", selection: $sttProvider) {
                    ForEach(STTProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                if sttProvider == STTProviderType.groq.rawValue {
                    SecureField("Groq API Key", text: $groqAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Picker("Model", selection: $groqModel) {
                        ForEach(groqModels, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }

                    Text("Groq transcribes after recording stops (no live text).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speech Recognition") {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(supportedLanguages) { lang in
                        Text(lang.displayName).tag(lang.localeIdentifier)
                    }
                }
            }

            Section("Keyboard Shortcuts") {
                HotkeyRecorderView(label: "Inline Recording")

                HotkeyRecorderView(
                    label: "Record Window",
                    keyCodeKey: SettingsKeys.recordWindowHotkeyKeyCode,
                    modifierFlagsKey: SettingsKeys.recordWindowHotkeyModifierFlags,
                    defaultKeyCode: 1,  // S
                    defaultModifierFlags: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue)
                )

                Text("Click a button, then press your desired shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Webhook") {
                TextField("Webhook URL", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Auth Token", text: $authToken)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if PasteService.isAccessibilityGranted {
                        Text("Granted")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            PasteService.promptAccessibility()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 480)
        .padding()
    }
}
