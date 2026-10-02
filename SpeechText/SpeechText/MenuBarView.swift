// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import ServiceManagement
import AppKit
import AVFoundation

/// The Settings window's content: a category sidebar and the page it picks, inside the
/// setup window's frame. The parts are in SettingsWindow.swift.
struct SettingsView: View {
    let window: SetupWindowRef
    @State private var category: SettingsCategory

    init(window: SetupWindowRef, category: SettingsCategory = .general) {
        self.window = window
        _category = State(initialValue: category)
    }

    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.localSTTModel) private var localSTTModelID = Provider.local.defaultSpeechModel
    @AppStorage(SettingsKeys.removeDisfluencies) private var removeDisfluencies = true
    @AppStorage(SettingsKeys.dashStyle) private var dashStyle = DashStyle.default.rawValue

    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""

    /// The API keys are not in UserDefaults (see `APIKeyStore`), so they are bound to the
    /// store rather than through `@AppStorage`; the store is observable, so the fields and
    /// the ready/needs-a-key statuses follow every edit.
    private var keys: APIKeyStore { APIKeyStore.shared }

    private func keyBinding(_ name: String) -> Binding<String> {
        Binding(get: { APIKeyStore.shared.value(for: name) },
                set: { APIKeyStore.shared.set($0, for: name) })
    }

    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false
    @AppStorage(SettingsKeys.escapeCancelsDictation) private var escapeCancelsDictation = false

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral
    @AppStorage(SettingsKeys.technoPhosphor) private var technoRaw = TechnoPhosphor.green.rawValue
    @AppStorage(SettingsKeys.dockIconMode) private var dockIconRaw = DockIconMode.default.rawValue

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    // Sparkle keeps this in its own defaults key, so it is read from the updater rather
    // than through @AppStorage.
    @State private var checksForUpdates = false
    // Read when the window opens and whenever the app comes back to the front — the user
    // grants both in System Settings, outside the app.
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = PasteService.isAccessibilityGranted

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

    /// The AI page is violet inside the card, as the setup window's AI step is; the
    /// frame's glow stays green.
    private var tint: SetupTint { category == .ai ? .violet : .green }

    var body: some View {
        SetupFrame {
            let card = RoundedRectangle(cornerRadius: 18, style: .continuous)
            HStack(spacing: 0) {
                SettingsSidebar(selection: $category, window: window)
                    .frame(width: Self.sidebarWidth)
                Rectangle().fill(SetupColor.separator).frame(width: 1)
                page
                    .frame(width: Self.pageWidth)
                    .frame(maxHeight: .infinity)
                    .environment(\.setupTint, tint)
                    .tint(tint.accent)
            }
            .background(card.fill(SettingsColor.background))
            .overlay(card.strokeBorder(SetupColor.cardRim, lineWidth: 0.5))
            .clipShape(card)
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            checksForUpdates = UpdateChecker.shared.checksAutomatically
            refreshPermissions()
            // A value left behind by a removed engine would render the picker blank.
            normalizeStoredProviders()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        // The main window asked for a page while the window was already open.
        .onReceive(NotificationCenter.default.publisher(for: .settingsShowCategory)) { note in
            if let asked = note.object as? SettingsCategory { category = asked }
        }
    }

    // MARK: - Page

    private static let sidebarWidth: CGFloat = 196
    /// The window, less the frame's rim, the sidebar and the hairline beside it.
    private static let pageWidth = SettingsWindow.size.width - 16 - sidebarWidth - 1

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(category.title).setupTitle(26)
                Text(category.lead).setupLead(13)
            }
            .frame(width: Self.pageWidth - 56, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 18)

            // A vertical ScrollView takes its width from its content, so the content is
            // given the page's width outright; otherwise a long caption widens the page
            // past the window.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .frame(width: Self.pageWidth - 56, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            // A new page starts at its top, not where the last one was scrolled to.
            .id(category)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general: generalPage
        case .appearance: appearancePage
        case .speech: speechPage
        case .formatting: formattingPage
        case .ai: aiPage
        case .apiKeys: apiKeysPage
        case .permissions: permissionsPage
        }
    }

    // MARK: - General

    /// Shortcuts first — they are what a user comes back to change — and updates last.
    @ViewBuilder
    private var generalPage: some View {
        shortcutGroups

        SettingsGroup(title: "Startup") {
            SettingsRow(title: "Launch at login", detail: "So SpeechText is ready when you start your Mac.") {
                SettingsSwitch(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard newValue != (SMAppService.mainApp.status == .enabled) else { return }
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
            SettingsDivider()
            SettingsRow(title: "Show in Dock", detail: "Adds SpeechText to the Dock and ⌘Tab, so its windows can be found once covered.") {
                Picker("Show in Dock", selection: $dockIconRaw) {
                    ForEach(DockIconMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: dockIconRaw) { _, _ in
                    NotificationCenter.default.post(name: .dockIconModeDidChange, object: nil)
                }
            }
        }

        SettingsGroup(title: UpdateChecker.shared.isConfigured ? "Updates" : "About") {
            // Absent in a build with no signing key, where the updater never starts.
            if UpdateChecker.shared.isConfigured {
                SettingsRow(title: "Check for updates automatically", detail: "Once a day. Nothing is installed until you agree.") {
                    SettingsSwitch(isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { _, newValue in
                            UpdateChecker.shared.checksAutomatically = newValue
                        }
                }
                SettingsDivider()
            }
            SettingsRow(title: "Version", detail: AppVersion.displayString) {
                if UpdateChecker.shared.isConfigured {
                    Button("Check Now…") { UpdateChecker.shared.checkForUpdates() }
                        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                }
            }
        }
    }

    // MARK: - Appearance

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }

    @ViewBuilder
    private var appearancePage: some View {
        SettingsGroup(title: "Style", inset: 5) {
            ForEach(AppSkin.allCases) { option in
                SettingsPreviewRow(title: option.displayName, detail: option.detail, isSelected: skin == option) {
                    guard skinRaw != option.rawValue else { return }
                    skinRaw = option.rawValue
                    NotificationCenter.default.post(name: .skinDidChange, object: nil)
                } preview: {
                    SkinPreview(skin: option, accentHex: accentHex, technoRaw: technoRaw)
                }
            }
        }

        SettingsGroup(title: "Colour") {
            if skin.supportsAccent {
                SettingsRow(title: "Accent",
                            detail: AccentColor.isNeutral(accentHex)
                                ? "Default — ink on glass, with a red record button."
                                : "Tints the level meter and the record button.") {
                    HStack(spacing: 8) {
                        ForEach(AccentColor.presets, id: \.hex) { preset in
                            swatch(preset)
                        }
                        ColorPicker(
                            "Colour",
                            selection: Binding(
                                get: { AccentColor.meter(accentHex) },
                                set: { accentHex = AccentColor.hex(from: $0) }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .help("Any colour")
                    }
                }
            } else {
                SettingsRow(title: "Display", detail: technoColorDetail) {
                    HStack(spacing: 8) {
                        ForEach(TechnoPhosphor.allCases) { option in
                            phosphorSwatch(option, selected: option == selectedPhosphor)
                        }
                        ColorPicker(
                            "Colour",
                            selection: Binding(
                                get: { TechnoPalette(stored: technoRaw).phosphor },
                                set: { technoRaw = AccentColor.hex(from: $0) }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .help("Any colour — the glass and the shell follow its hue")
                    }
                }
            }
        }
    }

    /// The recommended set the stored value names; nil for a colour of the user's own.
    /// A value that is neither reads as green, as the display does.
    private var selectedPhosphor: TechnoPhosphor? {
        if let preset = TechnoPhosphor(rawValue: technoRaw) { return preset }
        return TechnoPhosphor.customHex(technoRaw) == nil ? .green : nil
    }

    private var technoColorDetail: String {
        if let hex = TechnoPhosphor.customHex(technoRaw) {
            return TechnoPalette.isCloseToAI(hex)
                ? "Close to AI mode's violet — a plain dictation will be hard to tell from an AI one."
                : "Your colour, on glass of the same hue. AI mode stays violet."
        }
        switch selectedPhosphor {
        case .green, nil: return "Default — the green of the design."
        case let preset?: return "\(preset.displayName) dots and text on matching glass. AI mode stays violet."
        }
    }

    /// A display colour as the glass would show it: a lit dot on its own screen.
    private func phosphorSwatch(_ option: TechnoPhosphor, selected: Bool) -> some View {
        Button {
            technoRaw = option.rawValue
        } label: {
            Circle().fill(option.palette.screen)
                .overlay(Circle().fill(option.palette.phosphor).padding(4))
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(
                        selected ? AnyShapeStyle(SetupTint.green.accent) : AnyShapeStyle(SetupColor.label3),
                        lineWidth: selected ? 2 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .help(option.displayName)
    }

    private func swatch(_ preset: (name: String, hex: String)) -> some View {
        let selected = accentHex.caseInsensitiveCompare(preset.hex) == .orderedSame
        return Button {
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
                    selected ? AnyShapeStyle(SetupTint.green.accent) : AnyShapeStyle(SetupColor.label3),
                    lineWidth: selected ? 2 : 1
                )
            }
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    // MARK: - Speech

    @ViewBuilder
    private var speechPage: some View {
        SettingsGroup(title: "Engine", inset: 5) {
            ForEach(STTProviderType.allCases) { provider in
                // Only the chosen engine explains itself; five paragraphs at once is a wall.
                SetupRow(title: provider.displayName,
                         detail: provider == stt ? provider.subtitle : nil,
                         isSelected: provider == stt) {
                    sttProvider = provider.rawValue
                }
            }
        }

        switch stt {
        case .apple:
            EmptyView()
        case .local:
            SettingsGroup(title: "Model") {
                VStack(alignment: .leading, spacing: 8) {
                    LocalSpeechModelsView(selectedModelID: $localSTTModelID)
                }
                .font(.system(size: 13))
                .padding(.vertical, 12)
            }
        case .groq, .elevenlabs, .openai:
            if let setting = stt.vendor.descriptor.speechModel, let key = setting.settingsKey {
                // `.id` gives each engine its own picker: one kept across a switch would keep
                // the previous engine's stored key.
                SpeechModelGroup(provider: stt.vendor, settingsKey: key, defaultID: setting.defaultID,
                                 caption: setting.caption)
                    .id(stt)
            }
        }

        SettingsGroup(title: "Language") {
            SpokenLanguagesField(stt: stt)
        }

        // The words the engine is told live on the main window's Dictionary page, with
        // the switch that sends them; Settings only points there.
        SettingsGroup(title: "Dictionary") {
            SettingsRow(title: "Names and terms",
                        detail: "Words you want spelled your way — sent to the speech engine where it takes them, and put right in every dictation.") {
                Button("Open Dictionary", action: openDictionary)
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
            }
        }
    }

    private func openDictionary() {
        NotificationCenter.default.post(name: .openMainWindowPage, object: MainPage.dictionary.rawValue)
    }

    // MARK: - Formatting

    @ViewBuilder
    private var formattingPage: some View {
        SettingsGroup {
            SettingsRow(title: "Remove hesitation sounds",
                        detail: "Drops “е-е-е”, “а-а”, “м-м”, “um”, un-stretches words like “тооо”, and turns a trailing “...” into a full stop. Words like “ну” or “типу” are kept — use AI mode to rewrite those.") {
                SettingsSwitch(isOn: $removeDisfluencies)
            }
            SettingsDivider()
            SettingsRow(title: "Dashes",
                        detail: "Speech models write a long “—” where you paused between phrases. It is redrawn in this style, in dictations and AI output alike, and never removed.") {
                Picker("Dashes", selection: $dashStyle) {
                    ForEach(DashStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - AI

    @ViewBuilder
    private var aiPage: some View {
        SettingsGroup(title: "Provider", trailing: AnyView(aiStatus), inset: 5) {
            ForEach(LLMProviderType.allCases) { provider in
                SetupRow(title: provider.displayName, isSelected: provider == llm, compact: true) {
                    llmProvider = provider.rawValue
                }
            }
        }

        SettingsGroup(title: "Model") {
            switch llm {
            case .groq, .anthropic, .openai:
                if let key = llm.vendor.descriptor.chatModel?.settingsKey {
                    SettingsRow(title: "Text model") {
                        StoredModelPicker(settingsKey: key, defaultID: llm.vendor.defaultChatModel,
                                          models: chatModels(of: llm).map { (id: $0.id, name: $0.displayName) })
                    }
                    .id(llm)
                }
            case .ollama:
                VStack(alignment: .leading, spacing: 8) {
                    OllamaModelsView(selectedModelID: $ollamaModel)
                }
                .font(.system(size: 13))
                .padding(.vertical, 12)
            }
            SettingsDivider()
            SettingsNote("Separate from the speech model — you can transcribe with one provider and generate with another.")
                .padding(.vertical, 11)
        }

        SettingsGroup(title: "Prompts") {
            SettingsRow(title: "Prompts",
                        detail: "What a dictation can become — an email, a list, a translation. The model picks the one that matches what you said.") {
                Button("Edit Prompts…") { openPresets() }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
            }
        }

        SettingsGroup(title: "Context") {
            SettingsRow(title: "Where the text is going",
                        detail: "The AI Recording shortcut also sends the app's name, its window title and the text field's label, so the same words come out as a chat message in Slack and as a letter in Mail. Window titles can include email subjects and document names. Password managers and password fields are never read.")
        }
    }

    @ViewBuilder
    private var aiStatus: some View {
        if hasLLMKey {
            SettingsStatus(text: "Ready", ok: true)
        } else if llm.needsAPIKey {
            Button { category = .apiKeys } label: { SettingsStatus(text: "Needs an API key", ok: false) }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open API Keys")
        } else {
            SettingsStatus(text: "Needs a model", ok: false)
        }
    }

    // MARK: - API Keys

    /// Every key the app can use, in pipeline order (speech first). The ones the current
    /// choices use come first, marked with whether they are filled in; the rest stay
    /// below, so a key can be entered before the engine that needs it is picked.
    @ViewBuilder
    private var apiKeysPage: some View {
        let keys = apiKeys
        let inUse = keys.filter { !$0.active.isEmpty }
        let others = keys.filter { $0.active.isEmpty }
        SettingsGroup(title: "In use") {
            if inUse.isEmpty {
                SettingsRow(title: "Nothing to enter", detail: "Everything you've selected runs on this Mac.")
            } else {
                ForEach(inUse.indices, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    inUse[index].field(inUse: true)
                }
            }
        }
        if !others.isEmpty {
            SettingsGroup(title: "Other keys") {
                ForEach(others.indices, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    others[index].field(inUse: false)
                }
            }
        }
    }

    private struct APIKey {
        let service: Provider
        let value: Binding<String>
        /// Everything the key can be used for.
        let roles: [SettingsKeyRole]
        /// The roles the current choices use it for; empty when nothing does.
        let active: Set<SettingsKeyRole>

        /// The tags say what the key does; a caption is left for the one case they
        /// don't spell out — a single key serving both steps at once.
        var uses: String? {
            active.count > 1 ? "One key, used for both." : nil
        }

        func field(inUse: Bool) -> SettingsKeyField {
            SettingsKeyField(service: service, value: value, roles: roles, activeRoles: active,
                             uses: uses, inUse: inUse)
        }
    }

    /// Every provider with a key, speech before AI Rewrite (`APIKeyPage.order`). A key is
    /// in use for the step whose pick that provider serves — the selected engine, not where
    /// its uploads go, so Apple's engine does not mark Groq's key.
    private var apiKeys: [APIKey] {
        APIKeyPage.order.compactMap { provider in
            guard let key = provider.descriptor.apiKey else { return nil }
            let roles = provider.descriptor.roles
            var active: Set<SettingsKeyRole> = []
            if stt.vendor == provider { active.insert(.speech) }
            if llm.vendor == provider { active.insert(.aiRewrite) }
            return APIKey(service: provider, value: keyBinding(key.settingsKey),
                          roles: (roles.contains(.speech) ? [.speech] : []) + (roles.contains(.chat) ? [.aiRewrite] : []),
                          active: active)
        }
    }

    // MARK: - Shortcuts (on the General page)

    @ViewBuilder
    private var shortcutGroups: some View {
        SettingsGroup(title: "Shortcuts") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsDivider() }
                HotkeyRecorderView(action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                    .padding(.vertical, 9)
            }
        }
        SettingsNote("Click a shortcut, then press the new key combination.")
            .padding(.horizontal, 4)
            .padding(.top, -12)

        SettingsGroup(title: "Recording") {
            SettingsRow(title: "Hold to talk",
                        detail: holdToTalk
                            ? "Hold a recording shortcut while you speak and let go to paste. Once it's recording you can let go of the modifier keys — the letter alone keeps it going. A quick tap cancels; a double tap keeps recording hands-free until you press it again."
                            : "Press a recording shortcut to start, and press it again to stop.") {
                SettingsSwitch(isOn: $holdToTalk)
            }
            if holdToTalk {
                HoldToTalkDemo()
                    .padding(.vertical, 8)
            }
            SettingsNote(holdToTalk
                         ? "While holding, tap the other recording shortcut to switch between plain text and AI, as often as you like."
                         : "While recording, the other recording shortcut switches the dictation between plain text and AI.")
            SettingsNote(holdToTalk
                         ? "Edit Selection with AI: select text, hold the shortcut, say how to change it and let go. Double-press it to just polish the text; a single tap does nothing."
                         : "Edit Selection with AI: select text, press the shortcut, say how to change it and press it again. Double-press it to just polish the text.")
                .padding(.top, 6)
                .padding(.bottom, 12)
            SettingsDivider()
            SettingsRow(title: "Esc cancels a dictation",
                        detail: "While the recording overlay is on screen, Esc cancels it — and reaches no other app until the overlay is gone.") {
                SettingsSwitch(isOn: $escapeCancelsDictation)
            }
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsPage: some View {
        SettingsGroup {
            SettingsPermissionRow(symbol: "mic", title: "Microphone", detail: micDetail,
                                  granted: micStatus == .authorized) {
                if micStatus == .notDetermined {
                    Button("Allow") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { refreshPermissions() }
                        }
                    }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
                } else if micStatus == .denied {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
                }
            }
            SettingsDivider()
            SettingsPermissionRow(symbol: "keyboard", title: "Accessibility",
                                  detail: accessibilityGranted
                                      ? "So your words appear where your cursor is."
                                      : "Without it your text opens in the Record Window, ready to copy.",
                                  granted: accessibilityGranted) {
                Button("Grant Access") { PasteService.promptAccessibility() }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
            }
        }
    }

    private var micDetail: String {
        switch micStatus {
        case .denied: "Microphone is turned off for SpeechText."
        case .restricted: "Your Mac's settings don't allow microphone use. Ask whoever manages this Mac."
        default: "So SpeechText can hear you."
        }
    }

    private func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = PasteService.isAccessibilityGranted
    }

    // MARK: - Helpers

    /// Mirrors `LLMConfiguration.isConfigured`, but off the observed store and
    /// `@AppStorage`, so the status updates live while the key is being typed or a model
    /// is picked.
    private var hasLLMKey: Bool {
        _ = (llmProvider, ollamaModel)
        let value = llm.vendor.descriptor.apiKey.map { keys.value(for: $0.settingsKey) }
            ?? LLMConfiguration.model(for: llm)
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The prompts are a page of the main window now.
    private func openPresets() {
        NotificationCenter.default.post(name: .openMainWindowPage, object: MainPage.prompts.rawValue)
    }

}



// MARK: - Model pickers

/// A picker bound to one stored model setting, named at run time — the speech and chat
/// pickers for every provider. `.id` the view by provider where it is reused, so a switch
/// rebuilds it on the new key.
struct StoredModelPicker: View {
    let models: [(id: String, name: String)]
    @AppStorage private var selection: String

    init(settingsKey: String, defaultID: String, models: [(id: String, name: String)]) {
        self.models = models
        _selection = AppStorage(wrappedValue: defaultID, settingsKey)
    }

    var body: some View {
        Picker("Model", selection: $selection) {
            ForEach(models, id: \.id) { model in
                Text(model.name).tag(model.id)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The Speech page's model group for a cloud provider: the picker, the provider's caption,
/// and the selected model's own note (every realtime model explains its stream).
struct SpeechModelGroup: View {
    let provider: Provider
    let caption: String?
    @AppStorage private var selection: String

    init(provider: Provider, settingsKey: String, defaultID: String, caption: String?) {
        self.provider = provider
        self.caption = caption
        _selection = AppStorage(wrappedValue: defaultID, settingsKey)
    }

    var body: some View {
        SettingsGroup(title: "Model") {
            SettingsRow(title: "Speech model", detail: caption) {
                Picker("Model", selection: $selection) {
                    ForEach(sttModels(of: provider)) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let note = sttModel(vendor: provider, id: selection).settingsNote {
                SettingsDivider()
                SettingsNote(note)
                    .padding(.vertical, 11)
            }
        }
    }
}

// MARK: - Spoken languages

/// "Languages I speak", and the caption that says what it actually does.
///
/// The caption is not decoration. Naming one language forces it on every engine; naming
/// several cannot be passed to any provider (no API takes a set), so it only narrows the
/// guess Apple has to make. A control whose effect changes with the count — and with the
/// engine — has to say so, or it reads as a setting that does nothing.
private struct SpokenLanguagesField: View {
    @AppStorage(SettingsKeys.spokenLanguages) private var stored = ""
    @AppStorage(SettingsKeys.openAISTTModel) private var openAISTTModel = Provider.openAI.defaultSpeechModel
    let stt: STTProviderType

    private var selected: [String] { parseSpokenLanguages(stored) }

    /// The one engine that takes a *set* rather than a single language, so the only one
    /// where naming several changes what is sent — see `OpenAIRealtimeTranscriber`.
    private var narrowsToTheSet: Bool {
        stt == .openai && openAISTTModel == openAIRealtimeSTTModel
    }

    var body: some View {
        SettingsRow(title: "Languages I speak", detail: caption) {
            Menu {
                Button("Auto — detect every time") { stored = "" }
                Divider()
                ForEach(spokenLanguageCatalog) { language in
                    Toggle(language.displayName, isOn: binding(for: language.id))
                }
            } label: {
                Text(summary)
            }
            .frame(maxWidth: 200)
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(code) },
            // Appending rather than rebuilding from the catalogue keeps the user's own
            // order, which is what `resolveLocale` falls back to when the keyboard layout
            // matches none of them.
            set: { isOn in
                stored = encodeSpokenLanguages(isOn ? selected + [code] : selected.filter { $0 != code })
            }
        )
    }

    private var summary: String {
        let names = selected.compactMap { spokenLanguage(id: $0)?.displayName }
        return names.isEmpty ? "Auto — detect every time" : names.joined(separator: ", ")
    }

    private var caption: String {
        switch selected.count {
        case 0:
            return stt == .apple
                ? "Follows your active keyboard layout — currently \(resolvedLocale()). Apple's recogniser has no detect mode, so it always needs a language."
                : "Detected from what you say, by the speech model itself."
        case 1:
            let name = spokenLanguage(id: selected[0])?.displayName ?? selected[0]
            return "The engine is told you are speaking \(name), which is the most accurate setting — but anything you say in another language may come back translated into \(name)."
        default:
            if narrowsToTheSet {
                return "GPT Live Transcribe is told to choose among these languages instead of all of them — the only engine here that accepts a list."
            }
            return stt == .apple
                ? "Apple's recogniser cannot detect a language, so your keyboard layout picks one of yours — currently \(resolvedLocale())."
                : "The speech model detects which language you are speaking. This engine accepts only one language, so the list is not sent — name a single language to force one."
        }
    }
}

/// Settings › Hold to talk: the gesture played on a loop, the way System Settings shows a
/// trackpad gesture — the whole shortcut down, the modifiers let go while the letter
/// keeps recording, then the letter up (#79).
private struct HoldToTalkDemo: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let step = HoldTip.demoStep(at: context.date.timeIntervalSinceReferenceDate)
            let keys = shortcutKeys(shortcutText(for: .inline))
            let down = HoldTip.demoKeys(step)
            let caps = HoldTip.keycaps(modifiersDown: [down.modifiersDown], letterDown: down.letterDown, holdToTalk: true)
            let states = keys.map { isModifierCap($0) ? caps.modifiers[0] : caps.letter }
            HStack(spacing: 14) {
                SetupKeycaps(keys: keys, size: 22,
                             litKeys: states.indexes(of: .down), fadedKeys: states.indexes(of: .notNeeded),
                             ringKeys: states.contains(.notNeeded) ? states.indexes(of: .down) : [])
                    .frame(width: 96)
                Text(caption(step, keys: keys))
                    .font(.system(size: 12))
                    .foregroundStyle(SetupColor.label2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.2), value: step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold the shortcut to record; once recording, the letter alone keeps it going.")
    }

    private func caption(_ step: HoldTip.DemoStep, keys: [String]) -> String {
        let letter = keys.last ?? ""
        let modifiers = keys.filter(isModifierCap).joined()
        switch step {
        case .rest, .chord: return "Hold \(modifiers)\(letter)…"
        case .held: return "…recording."
        case .letterOnly: return "Let go of \(modifiers) — \(letter) alone keeps recording."
        case .done: return "Let go of \(letter) — the text is pasted."
        }
    }
}
