import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @AppStorage(SettingsKeys.webhookURL) private var webhookURL = ""
    @AppStorage(SettingsKeys.authToken) private var authToken = ""
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.groqAPIKey) private var groqAPIKey = ""
    @AppStorage(SettingsKeys.groqModel) private var groqModel = "whisper-large-v3-turbo"
    @AppStorage(SettingsKeys.elevenLabsAPIKey) private var elevenLabsAPIKey = ""
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = "scribe_v1"

    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.groqLLMModel) private var groqLLMModel = defaultGroqLLMModel
    @AppStorage(SettingsKeys.anthropicAPIKey) private var anthropicAPIKey = ""
    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = defaultAnthropicModel
    @AppStorage(SettingsKeys.openAIAPIKey) private var openAIAPIKey = ""
    @AppStorage(SettingsKeys.openAIModel) private var openAIModel = defaultOpenAIModel

    @AppStorage(SettingsKeys.messageSendingEnabled) private var messageSendingEnabled = false
    @State private var contactsAuthorized = ContactResolver.isAuthorized

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var presetsWindow: PromptPresetsWindow?

    // MARK: - Resolved selections
    //
    // Everything below reads through these instead of the raw strings, so a stored
    // value that no longer maps to a case can never leave a picker showing blank.

    private var stt: STTProviderType {
        STTProviderType(rawValue: sttProvider) ?? .apple
    }

    private var llm: LLMProviderType {
        LLMProviderType(rawValue: llmProvider) ?? .groq
    }

    /// The Groq key is one credential serving two independent steps.
    private var groqKeyUses: [String] {
        var uses: [String] = []
        if stt == .groq { uses.append("speech recognition") }
        if llm == .groq { uses.append("AI text generation") }
        return uses
    }

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
            contactsAuthorized = ContactResolver.isAuthorized
                        }
                    }
            }

            appearanceSection
            speechToTextSection
            aiProcessingSection
            messageDeliverySection
            apiKeysSection

            Section("Keyboard Shortcuts") {
                HotkeyRecorderView(label: "Inline Recording")

                HotkeyRecorderView(
                    label: "AI Recording",
                    keyCodeKey: SettingsKeys.aiHotkeyKeyCode,
                    modifierFlagsKey: SettingsKeys.aiHotkeyModifierFlags,
                    defaultKeyCode: 0,  // A
                    defaultModifierFlags: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue)
                )

                HotkeyRecorderView(
                    label: "Record Window",
                    keyCodeKey: SettingsKeys.recordWindowHotkeyKeyCode,
                    modifierFlagsKey: SettingsKeys.recordWindowHotkeyModifierFlags,
                    defaultKeyCode: 13,  // W
                    defaultModifierFlags: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue)
                )

                Text("Click a shortcut, then press the new key combination.")
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

                HStack {
                    Text("Contacts")
                    Spacer()
                    if contactsAuthorized {
                        Text("Granted")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            Task {
                                try? await ContactResolver.ensureAccess()
                                contactsAuthorized = ContactResolver.isAuthorized
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 500)
        .padding()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            contactsAuthorized = ContactResolver.isAuthorized
            // A value left behind by a removed engine would render the picker blank.
            normalizeStoredProviders()
        }
    }

    // MARK: - Appearance

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .minimal }

    private var appearanceSection: some View {
        Section {
            Picker("Style", selection: $skinRaw) {
                ForEach(AppSkin.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .onChange(of: skinRaw) { NotificationCenter.default.post(name: .skinDidChange, object: nil) }

            Text(skin.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if skin.supportsAccent {
                ColorPicker(
                    "Colour",
                    selection: Binding(
                        get: { AccentColor.meter(accentHex) },
                        set: { accentHex = AccentColor.hex(from: $0) }
                    ),
                    supportsOpacity: false
                )

                if AccentColor.isNeutral(accentHex) {
                    Text("Default — ink on glass, with a red record button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    ForEach(AccentColor.presets, id: \.hex) { preset in
                        let selected = accentHex.caseInsensitiveCompare(preset.hex) == .orderedSame
                        Button {
                            accentHex = preset.hex
                        } label: {
                            Group {
                                // The neutral swatch shows the glass itself, because
                                // that is literally what choosing it gets you.
                                if AccentColor.isNeutral(preset.hex) {
                                    Circle().fill(.ultraThinMaterial)
                                } else {
                                    Circle().fill(AccentColor.color(from: preset.hex))
                                }
                            }
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(
                                    .primary.opacity(selected ? 0.8 : 0.25),
                                    lineWidth: selected ? 2 : 1
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            } else {
                Text("Techno is drawn to a fixed design, so it keeps its own colours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Appearance")
        }
    }

    // MARK: - Step 1 · Speech → Text

    @ViewBuilder
    private var speechToTextSection: some View {
        Section {
            Picker("Engine", selection: $sttProvider) {
                ForEach(STTProviderType.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            Text(stt.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch stt {
            case .apple:
                EmptyView()
            case .groq:
                Picker("Speech Model", selection: $groqModel) {
                    ForEach(groqModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            case .elevenlabs:
                Picker("Speech Model", selection: $elevenLabsModel) {
                    ForEach(elevenLabsModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }

            Picker("Language", selection: $selectedLanguage) {
                ForEach(supportedLanguages) { lang in
                    Text(lang.displayName).tag(lang.localeIdentifier)
                }
            }
            if selectedLanguage == autoLanguageID {
                Text("Follows your active keyboard layout — currently \(resolvedLocale()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Step 1 · Speech → Text", "Turns what you say into raw text. Always runs.")
        }
    }

    // MARK: - Step 2 · Text → Text

    @ViewBuilder
    private var aiProcessingSection: some View {
        Section {
            Picker("Provider", selection: $llmProvider) {
                ForEach(LLMProviderType.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            switch llm {
            case .groq:
                Picker("Text Model", selection: $groqLLMModel) {
                    ForEach(groqChatModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            case .anthropic:
                Picker("Text Model", selection: $anthropicModel) {
                    ForEach(anthropicChatModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            case .openai:
                Picker("Text Model", selection: $openAIModel) {
                    ForEach(openAIChatModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }

            Text("Separate from the speech model above — you can transcribe with one provider and generate with another.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Edit Prompt Presets…") { openPresets() }
                Spacer()
                if hasLLMKey {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Needs an API key", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            sectionHeader(
                "Step 2 · Text → Text (AI)",
                "Optional. Runs only for the AI Recording shortcut and the ✨ toggle in the Record Window. What you dictate is the prompt — the model picks the matching preset and rewrites the text."
            )
        }
    }

    // MARK: - Message delivery

    private var messageDeliverySection: some View {
        Section {
            Toggle("Let dictations be sent as messages", isOn: $messageSendingEnabled)

            if messageSendingEnabled {
                let available = MessageDelivery.availableChannels
                if available.isEmpty {
                    Label("No supported messaging app found on this Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 10) {
                        ForEach(available) { channel in
                            Label(channel.displayName, systemImage: channel.symbolName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                // The channels split into two behaviours and the difference matters
                // before the first send, not after it.
                Text("Messages and Apple Mail are sent for you. Telegram and WhatsApp refuse to send from a link, so they open the chat with the text ready and you press ⏎. Nothing is ever sent without the confirmation panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !contactsAuthorized {
                    Label("Needs Contacts access to look up who you named.",
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            sectionHeader(
                "Step 3 · Text → Someone (experimental)",
                "Say who the message is for and where — “send Oksana on Telegram that I'm running late”. The recipient is looked up in your own Contacts; the app never invents an address."
            )
        }
    }

    // MARK: - Credentials

    @ViewBuilder
    private var apiKeysSection: some View {
        Section {
            if !groqKeyUses.isEmpty {
                SecureField("Groq", text: $groqAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("One key, used for \(groqKeyUses.joined(separator: " and ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if stt == .elevenlabs {
                SecureField("ElevenLabs", text: $elevenLabsAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used for speech recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if llm == .anthropic {
                SecureField("Anthropic", text: $anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            if llm == .openai {
                SecureField("OpenAI", text: $openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
            }
        } header: {
            sectionHeader("API Keys", "Only the keys your current selections actually use are shown.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    /// Mirrors `LLMConfiguration.isConfigured`, but off the @AppStorage bindings so
    /// the status updates live while the key is being typed.
    private var hasLLMKey: Bool {
        let key: String
        switch llm {
        case .groq: key = groqAPIKey
        case .anthropic: key = anthropicAPIKey
        case .openai: key = openAIAPIKey
        }
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func openPresets() {
        if let existing = presetsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = PromptPresetsWindow()
        window.makeKeyAndOrderFront(nil)
        presetsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
