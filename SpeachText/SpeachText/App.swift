import SwiftUI
import AppKit
import ServiceManagement

@main
struct SpeachTextApp: App {
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
    private var historyWindow: HistoryWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon(recording: false)

        // Build the menu
        rebuildMenu()

        // Request microphone access on first launch
        appState.speechEngine.requestMicrophoneAccess { granted in
            if !granted {
                dlog("App", "Microphone access denied")
            }
        }

        // Prompt for accessibility permission on first launch if not already granted.
        // This is required for pasting text at the cursor via the inline recorder.
        if !PasteService.isAccessibilityGranted {
            PasteService.promptAccessibility()
        }

        // Carry the pre-rename settings over, then drop provider values left over from
        // removed engines — both before any UI reads them.
        adoptPreRenameDefaults()
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

        // The status overlay asks for History via notification (AppState doesn't own windows)
        NotificationCenter.default.addObserver(
            forName: .openHistoryWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openHistory()
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

    /// The wordmark is wider than it is tall, so it gets a fixed height and its own
    /// aspect ratio rather than being squeezed into a square.
    private static func menuBarIcon(recording: Bool) -> NSImage? {
        guard let icon = NSImage(named: "MenuBarIcon") else { return nil }
        let height: CGFloat = 18
        icon.size = NSSize(width: (height * icon.size.width / icon.size.height).rounded(), height: height)
        // A template image is tinted by the system; recording needs its own colour.
        icon.isTemplate = !recording
        return icon
    }

    private func updateIcon() {
        statusItem.button?.image = Self.menuBarIcon(recording: appState.speechEngine.isRecording)
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

        let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "y")
        historyItem.target = self
        menu.addItem(historyItem)

        let debugItem = NSMenuItem(title: "Debug Log...", action: #selector(openDebugLog), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SpeachText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        window.title = "SpeachText Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() {
        if let existing = historyWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = HistoryWindow()
        window.makeKeyAndOrderFront(nil)
        historyWindow = window
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

extension Notification.Name {
    /// Posted when something (menu item, status overlay tap) wants the History window.
    /// AppDelegate owns the window, so AppState signals rather than opening it directly.
    static let openHistoryWindow = Notification.Name("openHistoryWindow")
}

// MARK: - AppState

@Observable
final class AppState {
    let speechEngine = SpeechEngine()
    let hotkeyManager = HotkeyManager()

    private var overlayPanel: RecordingOverlayPanel?
    private var statusPanel: StatusOverlayPanel?
    private var statusDismissItem: DispatchWorkItem?
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
    /// The task parked in `waitForTranscription()`. Cancelling the inline flow cancels
    /// it too: `cancelRecording()` moves the engine off `.finishing`, which resumes the
    /// waiter, and without the cancel it would run `handleTranscriptionResult()` over
    /// the cleared texts and pop "No speech detected" for an action the user asked for.
    private var transcriptionWaitTask: Task<Void, Never>?

    /// The pending "send this to X" confirmation, if one is on screen.
    private var confirmationPanel: SendConfirmationPanelWindow?
    private var recipientTask: Task<Void, Never>?

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
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        recipientTask?.cancel()
        recipientTask = nil
        isRefining = false
        speechEngine.cancelRecording()
        hideOverlay()
        hideSendConfirmation()
    }

    private func startRecording() {
        // A confirmation left over from the previous dictation would sit there holding a
        // send the user has moved on from.
        hideSendConfirmation()

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

    /// Suspends until the engine reports that transcription has finished, then handles
    /// the result. The engine resumes us from the same place it flips `isTranscribing`
    /// off, which is always after `finalText` / `errorMessage` / `lastRecordID` are set,
    /// so the ordering the old 50ms poll relied on is preserved without the polling.
    private func waitForTranscription() {
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            await speechEngine.awaitTranscription()
            // A cancel resumed us by moving the engine to `.idle` — there is no result
            // to handle, and reporting the cleared texts would claim "No speech detected".
            guard !Task.isCancelled else { return }
            dlog("App", "waitForTranscription: done (\(String(format: "%.2f", Date().timeIntervalSince(started)))s)")
            handleTranscriptionResult()
        }
    }

    private func handleTranscriptionResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("App", "handleTranscriptionResult: text=\(text.count) chars, previousApp=\(previousApp?.localizedName ?? "nil"), aiMode=\(isAIMode)")

        // A failed transcription used to end here silently — the user just saw nothing
        // happen and lost everything they said. Always surface it.
        if let rawError = speechEngine.errorMessage {
            dlog("App", "handleTranscriptionResult: error — \(rawError)")
            hideOverlay()
            showStatus(
                icon: "exclamationmark.triangle.fill",
                title: "Transcription failed",
                detail: friendlySTTError(rawError),
                tint: .orange
            )
            // Any partial text is better than nothing — hand it to the Record Window.
            // Refinement is skipped: there is no trustworthy transcript to rewrite.
            if !text.isEmpty {
                showDirectRecordingPanel(withText: text)
            }
            return
        }

        guard !text.isEmpty else {
            dlog("App", "handleTranscriptionResult: empty text")
            hideOverlay()
            showStatus(
                icon: "waveform.slash",
                title: "No speech detected",
                detail: "Nothing was transcribed from that recording.",
                tint: .secondary
            )
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
            showStatus(
                icon: "key.slash",
                title: "AI processing skipped",
                detail: "No API key for \(LLMConfiguration.providerType.displayName). Pasted the raw transcription.",
                tint: .orange
            )
            deliver(text)
            return
        }

        // Keep the overlay up (now in its loading state) while the LLM rewrites the text.
        isRefining = true
        let recordID = speechEngine.lastRecordID
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var output = text
            var sendIntent: TextRefinementService.SendIntent?
            do {
                let result = try await TextRefinementService.refine(text)
                if Task.isCancelled { return }
                output = result.text
                sendIntent = result.sendIntent
                if let recordID {
                    TranscriptionHistory.shared.recordRefinement(
                        id: recordID, input: text, output: result.text,
                        presetName: result.presetName,
                        provider: result.provider, model: result.model
                    )
                }
            } catch {
                if Task.isCancelled { return }
                if let recordID {
                    let type = LLMConfiguration.providerType
                    TranscriptionHistory.shared.recordRefinementFailure(
                        id: recordID, input: text, error: error.localizedDescription,
                        provider: type.rawValue, model: LLMConfiguration.model(for: type)
                    )
                }
                // Never lose the dictation: fall back to the raw transcript, but say so
                // rather than pasting unrewritten text with no explanation.
                dlog("App", "refinement failed (\(error.localizedDescription)) — pasting raw transcript")
                self.showStatus(
                    icon: "sparkles.slash",
                    title: "AI processing failed",
                    detail: "\(error.localizedDescription) Pasted the raw transcription.",
                    tint: .orange
                )
            }
            self.isRefining = false
            self.refinementTask = nil
            self.hideOverlay()

            // A dictation that named a recipient goes through the confirmation panel;
            // everything else keeps the ordinary paste-at-cursor behaviour.
            if let sendIntent {
                self.beginDelivery(sendIntent, body: output, recordID: recordID)
            } else {
                self.deliver(output)
            }
        }
    }

    // MARK: - Message delivery

    /// Resolves the spoken recipient to real addresses and puts the confirmation panel
    /// up. Any failure here falls back to pasting — a dictation is never lost because
    /// the address book came up short.
    private func beginDelivery(_ intent: TextRefinementService.SendIntent,
                               body: String, recordID: UUID?) {
        dlog("Send", "intent: \(intent.channel.rawValue) → “\(intent.recipient)”")

        recipientTask?.cancel()
        recipientTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recipientTask = nil }
            do {
                let candidates = try await ContactResolver.resolve(spoken: intent.recipient,
                                                                   channel: intent.channel)
                if Task.isCancelled { return }
                self.showSendConfirmation(
                    SendConfirmation(channel: intent.channel,
                                     candidates: candidates,
                                     subject: intent.subject ?? "",
                                     body: body),
                    recordID: recordID
                )
            } catch {
                if Task.isCancelled { return }
                dlog("Send", "could not resolve “\(intent.recipient)” — \(error.localizedDescription)")
                self.showStatus(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Couldn't find that recipient",
                    detail: "\(error.localizedDescription) Pasted the text instead.",
                    tint: .orange
                )
                self.deliver(body)
            }
        }
    }

    private func showSendConfirmation(_ confirmation: SendConfirmation, recordID: UUID?) {
        guard !confirmation.candidates.isEmpty else {
            dlog("Send", "no candidates to confirm — pasting instead")
            deliver(confirmation.body)
            return
        }
        hideSendConfirmation()

        let channel = confirmation.channel
        let hosting = NSHostingView(rootView: SendConfirmationView(
            confirmation: confirmation,
            onSend: { [weak self] recipient, subject, body in
                self?.performSend(body: body, subject: subject, to: recipient,
                                  via: channel, recordID: recordID)
            },
            onPasteInstead: { [weak self] body in
                self?.hideSendConfirmation()
                self?.deliver(body)
            },
            onCancel: { [weak self] in
                self?.hideSendConfirmation()
                self?.returnFocusToPreviousApp()
            }
        ))
        hosting.frame.size = hosting.fittingSize

        let panel = SendConfirmationPanelWindow(rootView: hosting)
        confirmationPanel = panel
        // The panel is a keyboard decision (⌘⏎ / ⎋), so unlike the recording overlays
        // it has to take focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func performSend(body: String, subject: String, to recipient: RecipientCandidate,
                             via channel: DeliveryChannel, recordID: UUID?) {
        hideSendConfirmation()
        do {
            let outcome = try MessageDelivery.deliver(body: body,
                                                      subject: subject.isEmpty ? nil : subject,
                                                      to: recipient, via: channel)
            if let recordID {
                TranscriptionHistory.shared.recordDelivery(
                    id: recordID, channel: channel, recipient: recipient,
                    outcome: outcome == .sent ? .sent : .composed
                )
            }
            switch outcome {
            case .sent:
                showStatus(icon: channel.symbolName,
                           title: "Sent to \(recipient.displayName)",
                           detail: "via \(channel.displayName)",
                           tint: Semantic.confirmation)
            case .composed(let hint):
                showStatus(icon: channel.symbolName,
                           title: "\(channel.displayName) is ready",
                           detail: hint,
                           tint: Semantic.ai)
            }
        } catch {
            dlog("Send", "delivery failed — \(error.localizedDescription)")
            if let recordID {
                TranscriptionHistory.shared.recordDelivery(
                    id: recordID, channel: channel, recipient: recipient,
                    outcome: .failed, error: error.localizedDescription
                )
            }
            showStatus(icon: "exclamationmark.triangle.fill",
                       title: "Couldn't send",
                       detail: "\(error.localizedDescription) Pasted the text instead.",
                       tint: .orange)
            deliver(body)
        }
    }

    private func hideSendConfirmation() {
        confirmationPanel?.close()
        confirmationPanel = nil
    }

    /// Cancelling should leave the user where they started, not in an empty menu-bar app.
    private func returnFocusToPreviousApp() {
        guard let app = previousApp else { return }
        PasteService.activateApp(app)
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
            // Blind wait on purpose: activation completes in the other app, which gives
            // us no signal for when it can take a ⌘V. Do not replace with a callback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                tryPaste()
            }
        }
    }

    func pasteTextToTarget(_ text: String) {
        dlog("App", "pasteTextToTarget: \(text.count) chars \"\(text.prefix(50))\", previousApp=\(previousApp?.localizedName ?? "nil")")

        // Re-activate the app the user was in before recording
        if let app = previousApp {
            PasteService.activateApp(app)
        } else {
            dlog("App", "pasteTextToTarget: no previousApp saved")
        }

        // Wait for the app to regain focus, then paste. A blind wait on purpose: focus
        // moves in another process and nothing tells us when its text field is ready
        // for ⌘V. No completion can replace this 0.5s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PasteService.pasteAtCursor(text)
        }
    }

    private func showOverlay() {
        // Close any existing panel first to prevent orphaned overlays
        hideOverlay()

        let panel = RecordingOverlayPanel()
        let hostingView = NSHostingView(rootView: ObservedOverlay(speechEngine: speechEngine, appState: self, onCancel: { [weak self, weak panel] in
            self?.transcriptionWaitTask?.cancel()
            self?.transcriptionWaitTask = nil
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

    // MARK: - Status Overlay

    func showStatus(icon: String, title: String, detail: String?, tint: Color, duration: TimeInterval = 5) {
        hideStatus()

        let panel = StatusOverlayPanel()
        panel.contentView = NSHostingView(rootView: StatusOverlayView(
            icon: icon,
            title: title,
            detail: detail,
            tint: tint,
            onTap: { [weak self] in
                self?.hideStatus()
                self?.openHistoryWindow()
            }
        ))
        panel.orderFrontRegardless()
        statusPanel = panel

        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            guard let self, self.statusPanel === panel else { return }
            self.hideStatus()
        }
        statusDismissItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    func openHistoryWindow() {
        NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
    }

    func hideStatus() {
        statusDismissItem?.cancel()
        statusDismissItem = nil
        statusPanel?.close()
        statusPanel = nil
    }

    /// Turn a raw provider error into something that tells the user what to actually do.
    private func friendlySTTError(_ raw: String) -> String {
        if raw.contains("413") || raw.localizedCaseInsensitiveContains("too large") {
            return "That recording was too large for the provider. Try a shorter one."
        }
        if raw.contains("429") {
            return "Rate limited by the provider. Wait a moment and retry from History."
        }
        if raw.contains("401") || raw.contains("403") {
            return "The API key was rejected. Check it in Settings."
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.contains("-1001") {
            return "The request timed out. Retry from History."
        }
        if raw.localizedCaseInsensitiveContains("offline") || raw.contains("-1009") {
            return "No internet connection. Retry from History once you're back online."
        }
        return raw
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
