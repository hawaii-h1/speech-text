import SwiftUI
import AppKit
import ServiceManagement

@main
struct VoicePeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate with NSStatusItem

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var settingsWindow: NSWindow?
    private var debugLogWindow: DebugLogWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
        }

        // Build the menu
        rebuildMenu()

        // Request microphone access on first launch
        appState.speechEngine.requestMicrophoneAccess { granted in
            if !granted {
                print("Microphone access denied!")
            }
        }

        // Prompt for accessibility permission on first launch if not already granted.
        // This is required for pasting text at the cursor via the inline recorder.
        if !PasteService.isAccessibilityGranted {
            PasteService.promptAccessibility()
        }

        // Drop provider values left over from removed engines before any UI reads them.
        normalizeStoredProviders()
        migrateHotkeyLayoutIfNeeded()

        // Set up hotkeys
        appState.hotkeyManager.onInlineToggle = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.toggleRecording()
                self?.updateIcon()
                self?.rebuildMenu()
            }
        }
        appState.hotkeyManager.onRecordWindowToggle = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.toggleOrShowDirectRecordingPanel()
            }
        }
        appState.hotkeyManager.onAIToggle = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.toggleRecording(aiMode: true)
                self?.updateIcon()
                self?.rebuildMenu()
            }
        }
        appState.hotkeyManager.start()

        // Rebuild menu when shortcuts change so display strings update
        NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildMenu()
        }

        // Auto-register as login item on first launch (default: ON)
        if !UserDefaults.standard.bool(forKey: SettingsKeys.hasRegisteredLaunchAtLogin) {
            UserDefaults.standard.set(true, forKey: SettingsKeys.hasRegisteredLaunchAtLogin)
            try? SMAppService.mainApp.register()
        }
    }

    /// Moves existing installs onto the current shortcut layout (Inline ⌃⇧Q,
    /// Record Window ⌃⇧W, AI ⌃⇧A). Clearing the stored values lets the new built-in
    /// defaults take effect; this runs once, so later customisations are kept.
    private func migrateHotkeyLayoutIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: SettingsKeys.hotkeyLayoutVersion) < 1 else { return }

        for key in [
            SettingsKeys.hotkeyKeyCode, SettingsKeys.hotkeyModifierFlags,
            SettingsKeys.recordWindowHotkeyKeyCode, SettingsKeys.recordWindowHotkeyModifierFlags,
            SettingsKeys.aiHotkeyKeyCode, SettingsKeys.aiHotkeyModifierFlags,
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(1, forKey: SettingsKeys.hotkeyLayoutVersion)
        dlog("App", "migrated shortcuts to the ⌃⇧Q / ⌃⇧W / ⌃⇧A layout")
    }

    private func updateIcon() {
        let icon = NSImage(named: "MenuBarIcon")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = !appState.speechEngine.isRecording // When recording, show as non-template (tinted)
        statusItem.button?.image = icon
        statusItem.button?.appearsDisabled = false
        if appState.speechEngine.isRecording {
            statusItem.button?.contentTintColor = .red
        } else {
            statusItem.button?.contentTintColor = nil
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let shortcut = currentShortcutDisplayString()
        if appState.speechEngine.isRecording {
            let stopItem = NSMenuItem(title: "Stop Recording (\(shortcut))", action: #selector(toggleRecording), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start Recording (\(shortcut))", action: #selector(toggleRecording), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        let aiShortcut = currentAIShortcutDisplayString()
        let aiTitle = appState.speechEngine.isRecording && appState.isAIMode
            ? "Stop AI Recording (\(aiShortcut))"
            : "AI Recording (\(aiShortcut))"
        let aiItem = NSMenuItem(title: aiTitle, action: #selector(toggleAIRecording), keyEquivalent: "")
        aiItem.target = self
        menu.addItem(aiItem)

        menu.addItem(.separator())

        let rwShortcut = currentRecordWindowShortcutDisplayString()
        let recordItem = NSMenuItem(title: "Record Window (\(rwShortcut))", action: #selector(openRecordPanel), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let debugItem = NSMenuItem(title: "Debug Log...", action: #selector(openDebugLog), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoicePeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
        updateIcon()
        rebuildMenu()
    }

    @objc private func toggleAIRecording() {
        appState.toggleRecording(aiMode: true)
        updateIcon()
        rebuildMenu()
    }

    @objc private func openRecordPanel() {
        appState.showDirectRecordingPanel()
    }

    @objc private func openSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePeter Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDebugLog() {
        if let existing = debugLogWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = DebugLogWindow()
        window.makeKeyAndOrderFront(nil)
        debugLogWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func currentShortcutDisplayString() -> String {
        let defaults = UserDefaults.standard
        let kc: UInt16
        let mf: NSEvent.ModifierFlags
        if defaults.object(forKey: SettingsKeys.hotkeyKeyCode) != nil {
            kc = UInt16(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode))
            mf = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.hotkeyModifierFlags)))
        } else {
            kc = 12   // Q
            mf = [.control, .shift]
        }
        return shortcutDisplayString(keyCode: kc, modifierFlags: mf)
    }

    private func currentRecordWindowShortcutDisplayString() -> String {
        let defaults = UserDefaults.standard
        let kc: UInt16
        let mf: NSEvent.ModifierFlags
        if defaults.object(forKey: SettingsKeys.recordWindowHotkeyKeyCode) != nil {
            kc = UInt16(defaults.integer(forKey: SettingsKeys.recordWindowHotkeyKeyCode))
            mf = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.recordWindowHotkeyModifierFlags)))
        } else {
            kc = 13   // W
            mf = [.control, .shift]
        }
        return shortcutDisplayString(keyCode: kc, modifierFlags: mf)
    }

    private func currentAIShortcutDisplayString() -> String {
        let defaults = UserDefaults.standard
        let kc: UInt16
        let mf: NSEvent.ModifierFlags
        if defaults.object(forKey: SettingsKeys.aiHotkeyKeyCode) != nil {
            kc = UInt16(defaults.integer(forKey: SettingsKeys.aiHotkeyKeyCode))
            mf = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.aiHotkeyModifierFlags)))
        } else {
            kc = 0   // A
            mf = [.control, .shift]
        }
        return shortcutDisplayString(keyCode: kc, modifierFlags: mf)
    }
}

// MARK: - AppState

@Observable
final class AppState {
    let speechEngine = SpeechEngine()
    let hotkeyManager = HotkeyManager()

    private var overlayPanel: RecordingOverlayPanel?
    private var resultPanel: ResultPanelWindow?
    private var directRecordingPanel: DirectRecordingPanelWindow?
    private var directRecordingSpeechEngine: SpeechEngine?
    /// The app the user was in before recording started (paste target)
    var previousApp: NSRunningApplication?

    /// True when the current inline session was started with the AI hotkey, so the
    /// transcription gets routed through `TextRefinementService` before pasting.
    private(set) var isAIMode = false
    /// True while the LLM is rewriting the transcription — keeps the overlay spinning.
    private(set) var isRefining = false
    private var refinementTask: Task<Void, Never>?

    func toggleRecording(aiMode: Bool = false) {
        dlog("App", "toggleRecording: isRecording=\(speechEngine.isRecording), isTranscribing=\(speechEngine.isTranscribing), isStartingEngine=\(speechEngine.isStartingEngine)")
        if speechEngine.isRecording {
            stopRecording()
        } else if speechEngine.isTranscribing || speechEngine.isStartingEngine || isRefining {
            dlog("App", "toggleRecording: cancelling mid-flight")
            cancelInlineFlow()
        } else {
            isAIMode = aiMode
            startRecording()
        }
    }

    /// Aborts recording, transcription and any in-flight LLM call, and drops the overlay.
    func cancelInlineFlow() {
        refinementTask?.cancel()
        refinementTask = nil
        isRefining = false
        speechEngine.cancelRecording()
        hideOverlay()
    }

    private func startRecording() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        dlog("App", "startRecording: previousApp=\(previousApp?.localizedName ?? "nil"), locale=\(resolvedLocale()), aiMode=\(isAIMode)")

        showOverlay()

        let locale = resolvedLocale()
        speechEngine.startRecording(locale: locale)
    }

    private func stopRecording() {
        dlog("App", "stopRecording")
        speechEngine.stopRecording()
        waitForTranscription()
    }

    private var transcriptionWaitCount = 0

    private func waitForTranscription() {
        guard speechEngine.isTranscribing else {
            dlog("App", "waitForTranscription: done (waited \(transcriptionWaitCount) cycles)")
            transcriptionWaitCount = 0
            handleTranscriptionResult()
            return
        }
        transcriptionWaitCount += 1
        if transcriptionWaitCount == 1 {
            dlog("App", "waitForTranscription: waiting for isTranscribing to become false…")
        } else if transcriptionWaitCount % 100 == 0 {
            dlog("App", "waitForTranscription: still waiting after \(transcriptionWaitCount) cycles (\(Double(transcriptionWaitCount) * 0.05)s)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForTranscription()
        }
    }

    private func handleTranscriptionResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("App", "handleTranscriptionResult: text=\(text.count) chars, previousApp=\(previousApp?.localizedName ?? "nil"), aiMode=\(isAIMode)")
        guard !text.isEmpty else {
            dlog("App", "handleTranscriptionResult: empty text, nothing to do")
            hideOverlay()
            return
        }

        guard isAIMode else {
            hideOverlay()
            deliver(text)
            return
        }

        guard TextRefinementService.isConfigured else {
            dlog("App", "handleTranscriptionResult: AI mode but no LLM API key — pasting raw transcript")
            hideOverlay()
            deliver(text)
            return
        }

        // Keep the overlay up (now in its loading state) while the LLM rewrites the text.
        isRefining = true
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var output = text
            do {
                let result = try await TextRefinementService.refine(text)
                if Task.isCancelled { return }
                output = result.text
            } catch {
                if Task.isCancelled { return }
                // Never lose the dictation: fall back to the raw transcript.
                dlog("App", "refinement failed (\(error.localizedDescription)) — pasting raw transcript")
            }
            self.isRefining = false
            self.refinementTask = nil
            self.hideOverlay()
            self.deliver(output)
        }
    }

    /// Pastes into the previously focused app, falling back to the Record Window when
    /// that isn't possible.
    private func deliver(_ text: String) {
        if !PasteService.isAccessibilityGranted {
            dlog("App", "deliver: no accessibility, showing record panel")
            PasteService.promptAccessibility()
            showDirectRecordingPanel(withText: text)
            return
        }

        guard let app = previousApp else {
            dlog("App", "deliver: no previousApp, showing record panel")
            showDirectRecordingPanel(withText: text)
            return
        }

        // Paste into the previous app. If the focused element is a known non-text
        // role (button, table, list, etc.), fall back to the Record Window instead.
        let alreadyFocused = app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier

        let tryPaste = { [weak self] in
            if PasteService.canLikelyPasteText(in: app) {
                PasteService.pasteAtCursor(text)
            } else {
                self?.showDirectRecordingPanel(withText: text)
            }
        }

        if alreadyFocused {
            tryPaste()
        } else {
            PasteService.activateApp(app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                tryPaste()
            }
        }
    }

    func pasteTextToTarget(_ text: String) {
        print("[AppState] pasteTextToTarget called, text: \(text.prefix(50))...")
        print("[AppState] previousApp: \(previousApp?.localizedName ?? "nil")")

        // Re-activate the app the user was in before recording
        if let app = previousApp {
            PasteService.activateApp(app)
        } else {
            print("[AppState] WARNING: no previousApp saved!")
        }

        // Wait for the app to regain focus, then paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PasteService.pasteAtCursor(text)
        }
    }

    private func showOverlay() {
        // Close any existing panel first to prevent orphaned overlays
        hideOverlay()

        let panel = RecordingOverlayPanel()
        let hostingView = NSHostingView(rootView: ObservedOverlay(speechEngine: speechEngine, appState: self, onCancel: { [weak self, weak panel] in
            self?.refinementTask?.cancel()
            self?.refinementTask = nil
            self?.isRefining = false
            self?.speechEngine.cancelRecording()
            // Close this specific panel regardless of what overlayPanel points to
            panel?.close()
            if self?.overlayPanel === panel {
                self?.overlayPanel = nil
            }
        }))
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        overlayPanel = panel
    }

    private func hideOverlay() {
        overlayPanel?.close()
        overlayPanel = nil
    }

    private func showResultPanel(text: String) {
        let panel = ResultPanelWindow()
        let hostingView = NSHostingView(rootView: ResultPanelView(
            text: text,
            onCopy: {},
            onSendToPeter: {},
            onDismiss: { [weak self] in
                self?.hideResultPanel()
            }
        ))
        panel.contentView = hostingView
        panel.center()
        panel.orderFrontRegardless()
        resultPanel = panel
    }

    private func hideResultPanel() {
        resultPanel?.close()
        resultPanel = nil
    }

    func toggleOrShowDirectRecordingPanel() {
        if directRecordingPanel != nil {
            toggleDirectRecordingState()
        } else {
            showDirectRecordingPanel()
        }
    }

    func toggleDirectRecordingState() {
        guard let engine = directRecordingSpeechEngine else { return }
        let locale = resolvedLocale()
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
        if engine.isRecording {
            withAnimation(spring) { engine.pauseRecording() }
        } else if engine.isPaused {
            withAnimation(spring) { engine.resumeRecording(locale: locale) }
        } else {
            withAnimation(spring) { engine.startRecording(locale: locale) }
        }
    }

    func showDirectRecordingPanel(withText text: String? = nil) {
        hideDirectRecordingPanel()

        // Save the app the user was in before opening the panel
        if text == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
        }

        let engine = SpeechEngine()
        if let text {
            engine.editedText = text
        }
        directRecordingSpeechEngine = engine

        let panel = DirectRecordingPanelWindow()
        let hostingView = NSHostingView(rootView: DirectRecordingPanelView(
            speechEngine: engine,
            appState: self,
            autoStartRecording: text == nil,
            onDismiss: { [weak self] in
                self?.hideDirectRecordingPanel()
            }
        ))
        panel.contentView = hostingView
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        directRecordingPanel = panel

        // Silent save on close: stop recording / let transcription finish, but don't paste
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let engine = self.directRecordingSpeechEngine {
                if engine.isRecording || engine.isPaused {
                    engine.stopRecording()
                }
                // If transcribing, let it finish on its own — don't cancel
            }
            self.directRecordingSpeechEngine = nil
            self.directRecordingPanel = nil
        }
    }

    private func hideDirectRecordingPanel() {
        if let engine = directRecordingSpeechEngine {
            if engine.isRecording || engine.isPaused {
                engine.stopRecording()
            }
        }
        directRecordingSpeechEngine = nil
        if let panel = directRecordingPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
            panel.close()
        }
        directRecordingPanel = nil
    }
}

/// A wrapper view that observes the SpeechEngine to update the waveform overlay
struct ObservedOverlay: View {
    @Bindable var speechEngine: SpeechEngine
    @Bindable var appState: AppState
    let onCancel: () -> Void

    var body: some View {
        RecordingOverlayView(
            barLevels: speechEngine.barLevels,
            isLoading: speechEngine.isTranscribing || appState.isRefining,
            isPreparing: speechEngine.isStartingEngine,
            isAIMode: appState.isAIMode,
            onCancel: onCancel
        )
    }
}
