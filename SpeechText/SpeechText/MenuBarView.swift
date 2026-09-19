// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.groqAPIKey) private var groqAPIKey = ""
    @AppStorage(SettingsKeys.groqModel) private var groqModel = "whisper-large-v3-turbo"
    @AppStorage(SettingsKeys.elevenLabsAPIKey) private var elevenLabsAPIKey = ""
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = defaultElevenLabsModel
    @AppStorage(SettingsKeys.localSTTModel) private var localSTTModelID = defaultLocalSTTModel
    @AppStorage(SettingsKeys.removeDisfluencies) private var removeDisfluencies = true
    @AppStorage(SettingsKeys.dashStyle) private var dashStyle = DashStyle.default.rawValue

    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.groqLLMModel) private var groqLLMModel = defaultGroqLLMModel
    @AppStorage(SettingsKeys.anthropicAPIKey) private var anthropicAPIKey = ""
    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = defaultAnthropicModel
    @AppStorage(SettingsKeys.openAIAPIKey) private var openAIAPIKey = ""
    @AppStorage(SettingsKeys.openAIModel) private var openAIModel = defaultOpenAIModel
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""

    @AppStorage(SettingsKeys.aiDraftWhileSpeaking) private var aiDraftWhileSpeaking = false
    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral
    @AppStorage(SettingsKeys.dockIconMode) private var dockIconRaw = DockIconMode.default.rawValue

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    // Sparkle keeps this in its own defaults key, so it is read from the updater rather
    // than through @AppStorage.
    @State private var checksForUpdates = false
    @State private var presetsWindow: PromptPresetsWindow?

    // MARK: - Resolved selections
    //
    // Everything below reads through these instead of the raw strings, so a stored
    // value that no longer maps to a case can never leave a picker showing blank.

    private var stt: STTProviderType {
        STTProviderType(rawValue: sttProvider) ?? .apple
    }

    /// The realtime model is selected: an inline dictation is built on the overlay and
    /// pasted once at the stop. Asked of `RecordingConfiguration` — the same answer
    /// `AppState` acts on — rather than re-derived here. The body re-renders on the
    /// `sttProvider` / `elevenLabsModel` storage it already reads.
    private var streamsLive: Bool {
        _ = (sttProvider, elevenLabsModel)
        return RecordingConfiguration.current(locale: autoLanguageID).streams
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
                        }
                    }

                Picker("Show in Dock", selection: $dockIconRaw) {
                    ForEach(DockIconMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .onChange(of: dockIconRaw) { _, _ in
                    NotificationCenter.default.post(name: .dockIconModeDidChange, object: nil)
                }

                // Absent in a build with no signing key, where the updater never starts.
                if UpdateChecker.shared.isConfigured {
                    Toggle("Check for Updates Automatically", isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { _, newValue in
                            UpdateChecker.shared.checksAutomatically = newValue
                        }
                    Button("Check Now...") { UpdateChecker.shared.checkForUpdates() }
                }
            }

            appearanceSection
            speechToTextSection
            aiProcessingSection
            apiKeysSection

            Section("Keyboard Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    HotkeyRecorderView(action: action)
                }

                Text("Click a shortcut, then press the new key combination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hold to talk", isOn: $holdToTalk)
                Text(holdToTalk
                     ? "Hold a recording shortcut while you speak and let go to paste. A quick tap cancels."
                     : "Press a recording shortcut to start, and press it again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(holdToTalk
                     ? "While holding, tap the other recording shortcut to switch between plain text and AI, as often as you like."
                     : "While recording, the other recording shortcut switches the dictation between plain text and AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(holdToTalk
                     ? "Edit Selection with AI: select text, hold the shortcut, say how to change it and let go. Double-press it to just polish the text; a single tap does nothing."
                     : "Edit Selection with AI: select text, press the shortcut, say how to change it and press it again. Double-press it to just polish the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 400, height: 648)
        .padding()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            checksForUpdates = UpdateChecker.shared.checksAutomatically
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
            case .local:
                LocalSpeechModelsView(selectedModelID: $localSTTModelID)
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
                if elevenLabsModel == elevenLabsRealtimeModel {
                    Text("Streams audio over a WebSocket, so words appear on the recording overlay as you say them — corrected as the sentence goes on — and are pasted in one go as soon as you stop. A 1 s pause ends a phrase. If the stream drops, the recording is uploaded to Scribe v2 instead. Realtime is billed per streamed minute — check your plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Sound tags like “(laughs)” are turned off, and fillers and false starts are dropped server-side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Language", selection: $selectedLanguage) {
                ForEach(supportedLanguages) { lang in
                    Text(lang.displayName).tag(lang.localeIdentifier)
                }
            }
            if selectedLanguage == autoLanguageID {
                // Auto means two different things, and saying so matters: a cloud model
                // detects the language from the audio, while Apple's recogniser has no
                // auto mode and has to be handed the keyboard layout's guess.
                Text(stt == .apple
                     ? "Follows your active keyboard layout — currently \(resolvedLocale())."
                     : "Detected from what you say, by the speech model itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Remove hesitation sounds", isOn: $removeDisfluencies)
            Text("Drops “е-е-е”, “а-а”, “м-м”, “um”, un-stretches words like “тооо”, and turns a trailing “...” into a full stop. Words like “ну” or “типу” are kept — use AI mode to rewrite those.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Dashes", selection: $dashStyle) {
                ForEach(DashStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            Text("Speech models write a long “—” where you paused between phrases. It is redrawn in this style, in dictations and AI output alike, and never removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            case .ollama:
                OllamaModelsView(selectedModelID: $ollamaModel)
            }

            Text("Separate from the speech model above — you can transcribe with one provider and generate with another.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("The AI Recording shortcut also sends the app's name, its window title and the text field's label, so the same words come out as a chat message in Slack and as a letter in Mail. Window titles can include email subjects and document names. Password managers and password fields are never read.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show the dictation while speaking, then swap in the AI version", isOn: $aiDraftWhileSpeaking)
                .disabled(streamsLive)
            Text(streamsLive
                 ? "With Scribe v2 Realtime the dictation is shown on the recording overlay instead, and only the AI version is pasted."
                 : "Only in apps whose text can be replaced reliably, like TextEdit and Notes. Browsers, Electron apps and terminals still get one paste at the end.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Edit Prompt Presets…") { openPresets() }
                Spacer()
                if hasLLMKey {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if llm.needsAPIKey {
                    Label("Needs an API key", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Needs a model", systemImage: "exclamationmark.triangle.fill")
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

            if groqKeyUses.isEmpty, stt != .elevenlabs, !llm.needsAPIKey {
                Text("Nothing to enter — everything you've selected runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        case .ollama: key = ollamaModel
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
