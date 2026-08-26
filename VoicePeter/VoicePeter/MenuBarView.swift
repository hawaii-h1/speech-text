import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(SettingsKeys.webhookURL) private var webhookURL = ""
    @AppStorage(SettingsKeys.authToken) private var authToken = ""
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = "apple"
    @AppStorage(SettingsKeys.groqAPIKey) private var groqAPIKey = ""
    @AppStorage(SettingsKeys.groqModel) private var groqModel = "whisper-large-v3-turbo"
    @AppStorage(SettingsKeys.elevenLabsAPIKey) private var elevenLabsAPIKey = ""
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = "scribe_v1"

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

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

                if sttProvider == STTProviderType.elevenlabs.rawValue {
                    SecureField("ElevenLabs API Key", text: $elevenLabsAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Picker("Model", selection: $elevenLabsModel) {
                        ForEach(elevenLabsModels, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }

                    Text("ElevenLabs transcribes after recording stops (no live text).")
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
        .frame(width: 380, height: 530)
        .padding()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
