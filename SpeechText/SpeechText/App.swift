// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import ServiceManagement

@main
struct SpeechTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Build identity

/// What this build is, in one line: the release version, and — when the rebuild
/// skill produced it — which commit it came from and when.
///
/// `CFBundleShortVersionString` is the semver in CHANGELOG.md and moves only on a
/// release. The rest is stamped at build time: `scripts/rebuild.sh` passes
/// `CURRENT_PROJECT_VERSION`, `SPT_GIT_COMMIT` and `SPT_BUILD_DATE` on the
/// `xcodebuild` line, and `Info.plist` carries `$(...)` placeholders for them.
/// A plain Xcode ⌘R build defines none of those, so the app says "dev" instead —
/// which is the honest answer, not a missing feature.
enum AppVersion {
    static var marketing: String { string(for: "CFBundleShortVersionString") ?? "?" }
    static var build: String { string(for: "CFBundleVersion") ?? "?" }
    static var commit: String? { string(for: "SPTGitCommit") }
    static var builtAt: String? { string(for: "SPTBuildDate") }

    /// e.g. `0.9.0 (build 47 · a18a7d1 · 2026-09-16 14:20)`, or `0.9.0 (dev)`.
    static var displayString: String {
        guard let commit else { return "\(marketing) (dev)" }
        var parts = ["build \(build)", commit]
        if let builtAt { parts.append(builtAt) }
        return "\(marketing) (\(parts.joined(separator: " · ")))"
    }

    /// An Info.plist string that is actually a value. Xcode substitutes an *empty*
    /// string for a build setting it was never given, so the unstamped case is ""
    /// rather than a missing key; a placeholder left verbatim would mean the key in
    /// Info.plist and the variable on the build line disagree, and showing the user
    /// `$(SPT_GIT_COMMIT)` is worse than showing nothing.
    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// Points `TranscriptJoin.isWord` at the macOS spell checker, so a segment boundary the
/// provider cut mid-word can be glued back. The language follows the script: the English
/// checker waves every Cyrillic word through, so it would call any fragment a word.
func registerSpellCheckedJoins() {
    let lock = NSLock()
    let uk = NSSpellChecker.shared.availableLanguages.contains("uk")
    TranscriptJoin.isWord = { word in
        let latin = word.unicodeScalars.allSatisfy { $0.isASCII }
        let cyrillic = word.unicodeScalars.allSatisfy { ("\u{0400}"..."\u{04FF}").contains($0) || $0 == "'" || $0 == "’" }
        let language: String
        if latin { language = "en" } else if cyrillic, uk { language = "uk" } else { return false }
        lock.lock(); defer { lock.unlock() }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
    dlog("App", "segment joins: spell checker registered (uk \(uk ? "available" : "missing"))")
}

// MARK: - AppDelegate with NSStatusItem

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var settingsWindow: NSWindow?
    private var debugLogWindow: DebugLogWindow?
    private var historyWindow: HistoryWindow?
    private var dockIcon: DockIconController?

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
        registerLocalSTT()
        registerSpellCheckedJoins()
        dockIcon = DockIconController()
        migrateHotkeyLayoutIfNeeded()

        // Starts Sparkle's background schedule. Nothing happens in a build with no
        // signing key, or in a development build — see UpdateChecker.
        _ = UpdateChecker.shared

        // Set up hotkeys
        appState.hotkeyManager.onDictationKey = { [weak self] key, isDown in
            DispatchQueue.main.async {
                if isDown {
                    self?.appState.hotkeyPressed(key)
                } else {
                    self?.appState.hotkeyReleased(key)
                }
                self?.updateIcon()
                self?.rebuildMenu()
            }
        }
        appState.hotkeyManager.onEditKey = { [weak self] isDown in
            DispatchQueue.main.async {
                if isDown {
                    self?.appState.editHotkeyPressed()
                } else {
                    self?.appState.editHotkeyReleased()
                }
                self?.updateIcon()
            }
        }
        appState.hotkeyManager.onRecordWindowToggle = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.toggleOrShowDirectRecordingPanel()
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

    /// A click on the Dock icon with nothing on screen opens Settings — otherwise the icon
    /// the user asked for would do nothing at all when clicked.
    func applicationWillTerminate(_ notification: Notification) {
        // History writes are coalesced; a record made in the last quarter second is
        // still pending here.
        TranscriptionHistory.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !DockIconController.hasOpenWindow() {
            openSettings()
        }
        return true
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

        // Which build is this? The app has no window and no About box, so the menu
        // is the only place the answer can live — and after a rebuild it is the
        // first thing worth checking.
        let versionItem = NSMenuItem(title: "SpeechText \(AppVersion.displayString)",
                                     action: #selector(copyVersion), keyEquivalent: "")
        versionItem.target = self
        versionItem.toolTip = "Click to copy this build's version"
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let shortcut = currentShortcutDisplayString()
        // During a dictation, the other mode's item switches it over rather than stopping it.
        let title = !appState.speechEngine.isRecording ? "Start Recording (\(shortcut))"
            : appState.isAIMode ? "Switch to Plain Text (\(shortcut))"
            : "Stop Recording (\(shortcut))"
        let recordingItem = NSMenuItem(title: title, action: #selector(toggleRecording), keyEquivalent: "")
        recordingItem.target = self
        menu.addItem(recordingItem)

        let aiShortcut = currentAIShortcutDisplayString()
        let aiTitle = !appState.speechEngine.isRecording ? "AI Recording (\(aiShortcut))"
            : appState.isAIMode ? "Stop AI Recording (\(aiShortcut))"
            : "Switch to AI (\(aiShortcut))"
        let aiItem = NSMenuItem(title: aiTitle, action: #selector(toggleAIRecording), keyEquivalent: "")
        aiItem.target = self
        menu.addItem(aiItem)

        let editItem = NSMenuItem(title: "Edit Selection with AI (\(currentEditShortcutDisplayString()))",
                                  action: #selector(toggleEdit), keyEquivalent: "")
        editItem.target = self
        editItem.toolTip = "Rewrites the text selected in the app in front. Speak an instruction, or double-press the shortcut to just polish it."
        menu.addItem(editItem)

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

        // Only where an update could actually be found: a build with no signing key has
        // no feed to check, and an item that always answers "no updates" is a lie.
        if UpdateChecker.shared.isConfigured {
            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SpeechText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates()
    }

    @objc private func copyVersion() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("SpeechText \(AppVersion.displayString)", forType: .string)
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

    @objc private func toggleEdit() {
        appState.toggleEdit()
        updateIcon()
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
        window.title = "SpeechText Settings"
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
        storedShortcutDisplayString(keyCodeKey: SettingsKeys.hotkeyKeyCode,
                                    modifiersKey: SettingsKeys.hotkeyModifierFlags,
                                    defaultKeyCode: 12)  // Q
    }

    private func currentRecordWindowShortcutDisplayString() -> String {
        storedShortcutDisplayString(keyCodeKey: SettingsKeys.recordWindowHotkeyKeyCode,
                                    modifiersKey: SettingsKeys.recordWindowHotkeyModifierFlags,
                                    defaultKeyCode: 13)  // W
    }

    private func currentAIShortcutDisplayString() -> String {
        storedShortcutDisplayString(keyCodeKey: SettingsKeys.aiHotkeyKeyCode,
                                    modifiersKey: SettingsKeys.aiHotkeyModifierFlags,
                                    defaultKeyCode: 0)  // A
    }

    private func currentEditShortcutDisplayString() -> String {
        storedShortcutDisplayString(keyCodeKey: SettingsKeys.editHotkeyKeyCode,
                                    modifiersKey: SettingsKeys.editHotkeyModifierFlags,
                                    defaultKeyCode: 14)  // E
    }

    /// The stored shortcut, or the built-in one (⌃⇧ + `defaultKeyCode`, matching
    /// `HotkeyManager`'s defaults) when none has been saved.
    private func storedShortcutDisplayString(keyCodeKey: String, modifiersKey: String,
                                             defaultKeyCode: UInt16) -> String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return shortcutDisplayString(keyCode: defaultKeyCode, modifierFlags: [.control, .shift])
        }
        return shortcutDisplayString(
            keyCode: UInt16(defaults.integer(forKey: keyCodeKey)),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifiersKey))))
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
    /// The block observer on the Record Window's `willClose`. Kept so it can be removed:
    /// `removeObserver(self, …)` does nothing for a block observer, and a leaked one from
    /// a previous panel cleared the *new* panel's references when the old one closed.
    private var directRecordingCloseObserver: NSObjectProtocol?
    /// The app the user was in before recording started (paste target)
    var previousApp: NSRunningApplication?

    /// True when the current inline session is in AI mode — started with the AI hotkey or
    /// switched to it — so the transcription gets routed through `TextRefinementService`
    /// before pasting.
    private(set) var isAIMode = false
    /// Where the dictation is going, read when its recording started. Sent only with an
    /// AI rewrite.
    private var focusContext: FocusContext?
    /// The current inline recording streams, so its text is built on the overlay and
    /// pasted once at the stop rather than span by span into the target app.
    private(set) var showsLiveTranscript = false
    /// True while the LLM is rewriting the transcription — keeps the overlay spinning.
    private(set) var isRefining = false
    private var refinementTask: Task<Void, Never>?
    /// The task parked in `waitForTranscription()`. Cancelling the inline flow cancels
    /// it too: `cancelRecording()` moves the engine off `.finishing`, which resumes the
    /// waiter, and without the cancel it would run `handleTranscriptionResult()` over
    /// the cleared texts and pop "No speech detected" for an action the user asked for.
    private var transcriptionWaitTask: Task<Void, Never>?

    /// This recording's delivery into the app it was started in: the tier, the spans
    /// pasted while the user speaks, the ledger, and the stop's correction.
    private let inlineDelivery = InlineDelivery()

    /// Presses and releases of the two dictation shortcuts, and whether the one that
    /// started a dictation is still held.
    private var hotkeyGesture = DictationHotkeyGesture()

    /// Where the inline flow is, in the terms the shortcuts care about.
    private var dictationPhase: DictationHotkeyGesture.Phase {
        if speechEngine.isTranscribing || isRefining { return .busy }
        if speechEngine.isStartingEngine { return .starting(ai: isAIMode) }
        if speechEngine.isRecording { return .recording(ai: isAIMode) }
        return .idle
    }

    /// A dictation shortcut went down.
    func hotkeyPressed(_ key: DictationHotkey) {
        // An edit's recording is an instruction, not a dictation: there is nothing for
        // a dictation shortcut to switch or stop, and the likeliest meaning of the press
        // is "not this, I want to dictate". It cancels the edit and does nothing more.
        if isEditMode {
            dlog("Hotkey", "\(key) pressed during an edit → cancel the edit")
            cancelEdit()
            return
        }
        hotkeyGesture.holdToTalk = UserDefaults.standard.bool(forKey: SettingsKeys.holdToTalk)
        let phase = dictationPhase
        let action = hotkeyGesture.press(key, in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "\(key) pressed in \(phase) → \(action)")
        perform(action)
    }

    /// A dictation shortcut came back up. Only acts with hold-to-talk on, and only for the
    /// shortcut that started the dictation.
    func hotkeyReleased(_ key: DictationHotkey) {
        guard !isEditMode else { return }
        let phase = dictationPhase
        let action = hotkeyGesture.release(key, in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "\(key) released in \(phase) → \(action)")
        perform(action)
    }

    /// The menu's items: a press with nothing held.
    func toggleRecording(aiMode: Bool = false) {
        if isEditMode {
            cancelEdit()
            return
        }
        dlog("App", "toggleRecording: isRecording=\(speechEngine.isRecording), isTranscribing=\(speechEngine.isTranscribing), isStartingEngine=\(speechEngine.isStartingEngine)")
        perform(hotkeyGesture.click(aiMode ? .ai : .inline, in: dictationPhase))
    }

    private func perform(_ action: DictationHotkeyAction) {
        switch action {
        case .start(let ai):
            isAIMode = ai
            startRecording()
        case .switchTo(let ai):
            switchMode(toAI: ai)
        case .stop:
            // A stop before the microphone opened has nothing to transcribe.
            if speechEngine.isRecording {
                stopRecording()
            } else {
                cancelInlineFlow()
            }
        case .cancel:
            dlog("App", "cancelling mid-flight")
            cancelInlineFlow()
        case .ignore:
            break
        }
    }

    /// The dictation carries on in the other mode. What is said stays one dictation;
    /// only its handling at the stop changes.
    private func switchMode(toAI: Bool) {
        if toAI {
            guard inlineDelivery.switchToAI() else {
                showStatus(
                    icon: "sparkles",
                    title: "Can't switch to AI now",
                    detail: "\(previousApp?.localizedName ?? "This app") already has the dictated text, and it can't be replaced with the AI version.",
                    tint: .orange
                )
                return
            }
            // Whatever is already in the document is now an AI draft, replaced at the stop.
            speechEngine.onSpansCommitted = nil
        }
        // Switching to plain text changes nothing while recording: the stop pastes what
        // was not delivered, which after an AI start is everything.
        dlog("App", "switching the dictation to \(toAI ? "AI" : "plain text")")
        isAIMode = toAI
        DictationTraceRecorder.record(.modeSwitch, text: toAI ? "ai" : "inline")
    }

    /// Aborts recording, transcription and any in-flight LLM call, and drops the overlay.
    func cancelInlineFlow() {
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        isRefining = false
        endInlineDelivery()
        DictationTraceRecorder.current = nil
        speechEngine.cancelRecording()
        hideOverlay()
    }

    private func startRecording() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        let locale = resolvedLocale()
        // The same settings the engine snapshots a moment later, read the same way.
        showsLiveTranscript = RecordingConfiguration.current(locale: locale).streams
        dlog("App", "startRecording: previousApp=\(previousApp?.localizedName ?? "nil"), locale=\(locale), aiMode=\(isAIMode), liveTranscript=\(showsLiveTranscript)")

        speechEngine.recordsEmptyOutcomes = true
        beginDeliveryPlan()
        showOverlay()

        // A start that fails (microphone refused, no input device, a stream that could
        // not open) never reaches a stop, and the "preparing" overlay used to sit there
        // until the next hotkey press.
        speechEngine.onStartFailure = { [weak self] message in
            self?.handleStartFailure(message)
        }
        speechEngine.startRecording(locale: locale)

        // After the engine start, not before: nothing reads it until the stop. Read for
        // a plain dictation too, because the AI shortcut can switch it over mid-way; it
        // leaves the machine only with an AI rewrite.
        focusContext = PasteService.readFocusContext(in: previousApp)
        if let focusContext {
            // The window title stays out of the system log — it can be a mail subject.
            dlog("Refine", "focus context: \(focusContext.appName ?? "?") (\(focusContext.bundleID ?? "?")), window title \(focusContext.windowTitle == nil ? "absent" : "present")")
        }
    }

    private func handleStartFailure(_ message: String) {
        dlog("App", "startRecording failed: \(message)")
        endInlineDelivery()
        DictationTraceRecorder.current = nil
        hideOverlay()
        showStatus(
            icon: "exclamationmark.triangle.fill",
            title: "Couldn't start recording",
            detail: friendlySTTError(message),
            tint: .orange
        )
    }

    // MARK: - Delivering while the user is still speaking

    /// Decides the tier for this recording and wires the engine up to it.
    private func beginDeliveryPlan() {
        // A live-transcript recording delivers nothing early, so its tier is never used —
        // and the probe is AX round trips to a possibly slow app ahead of the microphone.
        let probe = showsLiveTranscript ? AXTextProbe.unavailable : PasteService.probeFocusedText(in: previousApp)
        let tier = DeliveryTier.resolve(isOwnSurface: false, probe: probe)
        let aiDraft = UserDefaults.standard.bool(forKey: SettingsKeys.aiDraftWhileSpeaking)
        DictationTraceRecorder.current = DictationTraceRecorder.isEnabled
            ? DictationTraceRecorder(setup: DictationTrace.Setup(
                aiMode: isAIMode, aiDraft: aiDraft,
                removesDisfluencies: UserDefaults.standard.object(forKey: SettingsKeys.removeDisfluencies) as? Bool ?? true,
                dashStyle: .current,
                livePreview: showsLiveTranscript,
                app: previousApp?.localizedName,
                probe: .init(valueReadable: probe.valueReadable, rangeReadable: probe.rangeReadable,
                             rangeReadsBack: probe.rangeReadsBack)))
            : nil
        let progressive = inlineDelivery.begin(
            tier: tier, aiMode: isAIMode, aiDraft: aiDraft, livePreview: showsLiveTranscript,
            target: AccessibilityDeliveryTarget(app: previousApp),
            targetName: previousApp?.localizedName)

        speechEngine.onSpansCommitted = progressive
            ? { [weak self] spans in self?.inlineDelivery.enqueue(spans) }
            : nil
        speechEngine.onFinalize = { [weak self] input in self?.finalizeDelivery(input) }
    }

    /// The finalizing pass (`InlineDelivery.finalize`), with its outcome written to History.
    private func finalizeDelivery(_ input: SpeechEngine.FinalizeInput) {
        // An AI draft is not corrected to the raw transcript first: that would be two
        // writes where one will do. `deliverAIResult` replaces it once the rewrite is in.
        guard !isAIMode else { return }
        let applied = inlineDelivery.finalize(text: input.text, hasFrozenSpans: input.hasFrozenSpans)
        if let applied { DictationTraceRecorder.record(.correction, applied: applied) }
        if let applied, let id = input.recordID {
            TranscriptionHistory.shared.recordCorrection(id: id, applied: applied)
        }
    }

    /// Stops offering spans. The ledger is kept: the stop still has to know what the
    /// app was given so it can hand over the rest and not the whole thing again.
    private func stopOfferingSpans() {
        speechEngine.onSpansCommitted = nil
        inlineDelivery.stopOffering()
    }

    /// The recording was abandoned. Nothing more goes out, and the ledger goes with it.
    private func endInlineDelivery() {
        speechEngine.onSpansCommitted = nil
        speechEngine.onFinalize = nil
        inlineDelivery.end()
    }

    private func stopRecording() {
        dlog("App", "stopRecording")
        DictationTraceRecorder.record(.stop)
        // From here the authoritative text arrives through the result path, and anything
        // still queued would be delivered twice. The ledger stays — the stop needs it to
        // know what the app has already been given.
        stopOfferingSpans()
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
            // A span pasted just before the stop reaches the ledger only once it has landed.
            await withCheckedContinuation { continuation in
                self.inlineDelivery.whenIdle { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            dlog("App", "waitForTranscription: done (\(String(format: "%.2f", Date().timeIntervalSince(started)))s)")
            handleTranscriptionResult()
        }
    }

    private func handleTranscriptionResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("App", "handleTranscriptionResult: text=\(text.count) chars, previousApp=\(previousApp?.localizedName ?? "nil"), aiMode=\(isAIMode)")

        let result = inlineDelivery.stopResult(finalText: text,
                                               failed: speechEngine.errorMessage != nil,
                                               aiMode: isAIMode,
                                               recordingText: speechEngine.spanLayer.text)
        switch result {
        case .failed(let partial):
            // A failed transcription used to end here silently — the user just saw nothing
            // happen and lost everything they said. Always surface it.
            let rawError = speechEngine.errorMessage ?? ""
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
            if let partial, !partial.isEmpty {
                showDirectRecordingPanel(withText: partial.trimmingCharacters(in: .whitespaces))
            }

        case .noSpeech:
            dlog("App", "handleTranscriptionResult: empty text")
            hideOverlay()
            showStatus(
                icon: "waveform.slash",
                title: "No speech detected",
                detail: "Nothing was transcribed from that recording.",
                tint: .secondary
            )

        case .alreadyDelivered:
            dlog("App", "handleTranscriptionResult: empty text")
            hideOverlay()
            dlog("App", "handleTranscriptionResult: empty final text, but the dictation was already delivered")

        case .notPasted:
            hideOverlay()
            // The final text re-words what is already in the document too much to tell
            // where it ends, so nothing more was pasted rather than a second copy. The
            // words are in History; say so instead of dropping them silently.
            showStatus(
                icon: "text.badge.xmark",
                title: "Part of the dictation wasn't pasted",
                detail: "The final transcript differs from what was already typed. Click to see it in History.",
                tint: .orange,
                duration: 8
            )

        case .nothingLeft:
            hideOverlay()
            // Everything was already pasted as it was committed — which is the point of
            // the exercise, not a failure of it.
            dlog("App", "handleTranscriptionResult: nothing left to paste")

        case .paste(let remainder):
            hideOverlay()
            deliver(remainder)

        case .refine(let aiInput):
            // The trace is finished once the rewrite has been delivered.
            refine(aiInput)
            return
        }
        finishTrace()
    }

    /// Writes the dictation's trace, when one is being recorded.
    private func finishTrace() {
        guard let recorder = DictationTraceRecorder.current else { return }
        DictationTraceRecorder.current = nil
        if let url = recorder.write(into: DictationTraceRecorder.directory) {
            dlog("Trace", "trace written: \(url.lastPathComponent)")
        }
    }

    /// AI mode's half of the stop: the LLM rewrites `aiInput`, and the result is pasted,
    /// sent, or — on any failure — replaced by the raw transcript.
    private func refine(_ aiInput: String) {
        guard TextRefinementService.isConfigured else {
            dlog("App", "handleTranscriptionResult: AI mode but LLM not configured — pasting raw transcript")
            hideOverlay()
            let type = LLMConfiguration.providerType
            showStatus(
                icon: "key.slash",
                title: "AI processing skipped",
                detail: type.needsAPIKey
                    ? "No API key for \(type.displayName). Pasted the raw transcription."
                    : "No \(type.displayName) model selected. Pasted the raw transcription.",
                tint: .orange
            )
            DictationTraceRecorder.record(.refinement, error: "not configured")
            deliverAIResult(aiInput, recordID: speechEngine.lastRecordID)
            finishTrace()
            return
        }

        // Keep the overlay up (now in its loading state) while the LLM rewrites the text.
        isRefining = true
        let recordID = speechEngine.lastRecordID
        let context = focusContext
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var output = aiInput
            do {
                let result = try await TextRefinementService.refine(aiInput, context: context)
                if Task.isCancelled { return }
                output = result.text
                DictationTraceRecorder.record(.refinement, text: result.text)
                if let recordID {
                    TranscriptionHistory.shared.recordRefinement(
                        id: recordID, input: aiInput, output: result.text,
                        presetName: result.presetName,
                        provider: result.provider, model: result.model,
                        context: context
                    )
                }
            } catch {
                if Task.isCancelled { return }
                if let recordID {
                    let type = LLMConfiguration.providerType
                    TranscriptionHistory.shared.recordRefinementFailure(
                        id: recordID, input: aiInput, error: error.localizedDescription,
                        provider: type.rawValue, model: LLMConfiguration.model(for: type),
                        context: context
                    )
                }
                DictationTraceRecorder.record(.refinement, error: error.localizedDescription)
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
            self.deliverAIResult(output, recordID: recordID)
            self.finishTrace()
        }
    }

    /// Where an AI dictation's final text goes — see `InlineDelivery.deliverAIResult`.
    private func deliverAIResult(_ output: String, recordID: UUID?) {
        let hasFrozenSpans = speechEngine.spanLayer.spans.contains { $0.state == .frozen }
        let (paste, applied) = inlineDelivery.deliverAIResult(output, hasFrozenSpans: hasFrozenSpans)
        if let applied { DictationTraceRecorder.record(.correction, applied: applied) }
        if let applied, let recordID {
            TranscriptionHistory.shared.recordCorrection(id: recordID, applied: applied)
        }
        if let paste {
            deliver(paste)
        }
    }

    /// Pastes into the previously focused app, falling back to the Record Window when
    /// that isn't possible.
    private func deliver(_ text: String) {
        DictationTraceRecorder.record(.stopPaste, text: text)
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

    // MARK: - Editing the selection

    /// Where the edit's selected text is.
    private enum EditRemoval {
        /// Still in the document, selected.
        case inPlace
        /// The ⌘X is on its way.
        case removing
        /// Cut. `original` is the pasteboard as the ⌘X left it, formatting included, so an
        /// edit that fails or is cancelled puts back exactly what was there.
        case removed(original: [NSPasteboardItem], text: String)
        /// The ⌘X changed nothing — a read-only field. The rewrite ends on the clipboard.
        case notRemovable
    }

    /// The spoken instruction, from the microphone to the text the LLM is given.
    private enum EditInstruction {
        case listening
        case transcribing
        /// Nil text: none was given (a double press, or nothing said).
        case ready(String?, recordID: UUID?)
    }

    /// True from the Edit shortcut's first press until its rewrite is written or dropped.
    /// The overlay turns violet-filled with the pencil glyph; the dictation shortcuts
    /// cancel instead of acting.
    private(set) var isEditMode = false
    private var editGesture = EditHotkeyGesture()
    /// The selection being edited, once it has been read.
    private var editSelection: CapturedSelection?
    private var isReadingSelection = false
    private var editRemoval = EditRemoval.inPlace
    /// The instruction is over: the selection goes as soon as it has been read.
    private var removesSelection = false
    private var editInstruction = EditInstruction.listening
    /// Fires `doubleTapWindow` after a hold-to-talk tap, which cancels unless a second
    /// press came first.
    private var editTapTimer: DispatchWorkItem?
    /// Bumped whenever an edit ends, so a callback from the one before — a ⌘C or ⌘X poll,
    /// a transcription, an LLM reply — cannot act on the next.
    private var editGeneration = 0

    /// Where the edit is, in the terms the Edit shortcut cares about.
    private var editPhase: EditHotkeyGesture.Phase {
        guard isEditMode else { return .idle }
        if speechEngine.isStartingEngine { return .starting }
        if speechEngine.isRecording { return .recording }
        return .busy
    }

    /// The Edit shortcut went down.
    func editHotkeyPressed() {
        guard isEditMode || dictationPhase == .idle else {
            dlog("Hotkey", "edit pressed during a dictation → ignored")
            return
        }
        if !isEditMode {
            editGesture.holdToTalk = UserDefaults.standard.bool(forKey: SettingsKeys.holdToTalk)
        }
        let phase = editPhase
        let action = editGesture.press(in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "edit pressed in \(phase) → \(action)")
        perform(action)
    }

    /// The Edit shortcut came back up.
    func editHotkeyReleased() {
        guard isEditMode else { return }
        let phase = editPhase
        let action = editGesture.release(in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "edit released in \(phase) → \(action)")
        perform(action)
        if editGesture.awaitsSecondTap {
            scheduleEditTapTimer()
        }
    }

    /// The menu's item: a press with nothing held.
    func toggleEdit() {
        guard isEditMode || dictationPhase == .idle else { return }
        perform(editGesture.click(in: editPhase))
    }

    private func scheduleEditTapTimer() {
        editTapTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.editTapTimer = nil
            let action = self.editGesture.tapWindowExpired(in: self.editPhase, at: ProcessInfo.processInfo.systemUptime)
            dlog("Hotkey", "edit tap stood alone → \(action)")
            self.perform(action)
        }
        editTapTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + EditHotkeyGesture.doubleTapWindow, execute: timer)
    }

    private func perform(_ action: EditHotkeyAction) {
        switch action {
        case .start:
            startEdit()
        case .send:
            sendEdit()
        case .sendWithoutInstruction:
            dlog("Edit", "double press — no instruction")
            editTapTimer?.cancel()
            editTapTimer = nil
            // A microphone still starting may yet fail; that no longer concerns this edit.
            speechEngine.onStartFailure = nil
            speechEngine.cancelRecording()
            editInstruction = .ready(nil, recordID: nil)
            removesSelection = true
            advanceEdit()
        case .cancel:
            cancelEdit()
        case .ignore:
            break
        }
    }

    /// Reads the selection and opens the microphone for an instruction, together.
    private func startEdit() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            editGesture.reset()
            showStatus(icon: "character.cursor.ibeam", title: "Nothing to edit here",
                       detail: "Select text in another app, then press the Edit shortcut.", tint: .secondary)
            return
        }
        guard PasteService.isAccessibilityGranted else {
            editGesture.reset()
            PasteService.promptAccessibility()
            showStatus(icon: "hand.raised.fill", title: "Accessibility access needed",
                       detail: "SpeechText needs it to read the selected text and replace it.", tint: .orange)
            return
        }
        previousApp = front
        editGeneration += 1
        let generation = editGeneration
        isEditMode = true
        isAIMode = false
        editSelection = nil
        isReadingSelection = true
        editRemoval = .inPlace
        removesSelection = false
        editInstruction = .listening
        // Nothing of the instruction is ever delivered: no spans while speaking, no
        // finalizing pass at the stop.
        endInlineDelivery()
        DictationTraceRecorder.current = nil
        let locale = resolvedLocale()
        showsLiveTranscript = RecordingConfiguration.current(locale: locale).streams
        dlog("Edit", "start: app=\(front?.localizedName ?? "nil"), holdToTalk=\(editGesture.holdToTalk), liveTranscript=\(showsLiveTranscript)")
        showOverlay()

        // Read first, while the app is certainly in front and before the engine's start
        // competes with the ⌘C. The answer is handled on a later turn of the run loop even
        // when AX gave it at once, so the engine below has started by then and a "nothing
        // selected" cancel stops it rather than running ahead of it.
        PasteService.readSelection(in: front) { [weak self] read in
            DispatchQueue.main.async {
                guard let self, self.isEditMode, self.editGeneration == generation else { return }
                self.selectionRead(read)
            }
        }
        speechEngine.onStartFailure = { [weak self] message in
            guard let self, self.isEditMode, self.editGeneration == generation else { return }
            dlog("Edit", "microphone failed to start: \(message)")
            self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't start recording",
                           detail: self.friendlySTTError(message))
        }
        // Saying nothing is a request to polish, and the edit writes its own record.
        speechEngine.recordsEmptyOutcomes = false
        speechEngine.startRecording(locale: locale)
        focusContext = PasteService.readFocusContext(in: front)
    }

    private func selectionRead(_ read: PasteService.SelectionRead) {
        isReadingSelection = false
        switch read {
        case .nothingSelected:
            abortEdit(icon: "character.cursor.ibeam", title: "No text selected",
                      detail: "Select the text to rework, then press the Edit shortcut.", tint: .secondary)
        case .selected(let selection):
            guard selection.text.count <= SelectionEdit.maxCharacters else {
                abortEdit(icon: "text.badge.xmark", title: "Selection too long",
                          detail: "Select up to \(SelectionEdit.maxCharacters.formatted()) characters to edit with AI.")
                return
            }
            editSelection = selection
            advanceEdit()
        }
    }

    /// Closes the microphone and takes the selection out while the instruction is
    /// transcribed.
    private func sendEdit() {
        guard speechEngine.isRecording else {
            // Stopped before the microphone opened: whatever was said went nowhere, and a
            // rewrite without it would not be what was asked for.
            abortEdit(icon: "mic.slash", title: "The microphone wasn't ready",
                      detail: "Nothing was changed. Try again — or double-press to edit without an instruction.")
            return
        }
        let generation = editGeneration
        editInstruction = .transcribing
        removesSelection = true
        speechEngine.stopRecording()
        advanceEdit()
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.speechEngine.awaitTranscription()
            guard !Task.isCancelled, self.isEditMode, self.editGeneration == generation else { return }
            self.transcriptionWaitTask = nil
            if let error = self.speechEngine.errorMessage {
                dlog("Edit", "instruction failed: \(error)")
                self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't understand the instruction",
                               detail: self.friendlySTTError(error))
                return
            }
            let instruction = self.speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing said is the same as a double press: polish.
            self.editInstruction = .ready(instruction.isEmpty ? nil : instruction,
                                          recordID: instruction.isEmpty ? nil : self.speechEngine.lastRecordID)
            self.advanceEdit()
        }
    }

    /// Moves the edit on as far as what has arrived allows: once the instruction is over
    /// and the selection read, the selection is cut; once it is cut and the instruction
    /// transcribed, the LLM gets both. Called whenever one of those lands.
    private func advanceEdit() {
        guard isEditMode, let selection = editSelection else { return }
        if removesSelection, case .inPlace = editRemoval {
            takeSelection(selection)
            return
        }
        guard case .ready(let instruction, let recordID) = editInstruction, refinementTask == nil else { return }
        switch editRemoval {
        case .inPlace, .removing: return
        case .removed, .notRemovable: runEdit(selection, instruction: instruction, recordID: recordID)
        }
    }

    /// The instruction is over: the selection is cut, so nothing the user does while the
    /// LLM works can make the rewrite land on the wrong text. The rewrite is then pasted
    /// at the caret the cut leaves.
    private func takeSelection(_ selection: CapturedSelection) {
        removeSelection(selection)
    }

    /// Cuts the selection, and checks that what was cut is what was read: a click
    /// elsewhere since then would otherwise have taken other text out of the document.
    private func removeSelection(_ selection: CapturedSelection) {
        editRemoval = .removing
        let generation = editGeneration
        if let record = selection.record, let app = previousApp,
           PasteService.select(record, in: app) == .changed {
            abortEdit(icon: "text.badge.xmark", title: "The selected text changed",
                      detail: "It was left as it was.")
            return
        }
        PasteService.cutSelection { [weak self] cut in
            guard let self, self.isEditMode, self.editGeneration == generation else {
                // The edit was cancelled while the ⌘X was landing: nothing may go missing.
                if case .cut(let items, _) = cut { PasteService.pasteItems(items) }
                return
            }
            switch cut {
            case .nothing:
                dlog("Edit", "the selection could not be cut — the rewrite will go to the clipboard")
                self.editRemoval = .notRemovable
            case .cut(let items, let text):
                guard SelectionEdit.cutMatches(text, selection: selection.text) else {
                    dlog("Edit", "cut \(text.count) chars that are not the selection — putting them back")
                    PasteService.pasteItems(items)
                    self.abortEdit(icon: "text.badge.xmark", title: "The selection changed",
                                   detail: "Nothing was changed.")
                    return
                }
                dlog("Edit", "selection cut (\(text.count) chars)")
                self.editRemoval = .removed(original: items, text: text)
            }
            self.advanceEdit()
        }
    }

    /// Sends the selection to the LLM and writes the answer where it was.
    private func runEdit(_ selection: CapturedSelection, instruction: String?, recordID: UUID?) {
        guard TextRefinementService.isConfigured else {
            let type = LLMConfiguration.providerType
            abortEdit(icon: "key.slash", title: "AI isn't set up",
                      detail: type.needsAPIKey
                          ? "Add a \(type.displayName) API key in Settings to edit text with AI."
                          : "Choose a \(type.displayName) model in Settings to edit text with AI.")
            return
        }

        dlog("Edit", "rewriting \(selection.text.count) chars, instruction: \(instruction == nil ? "none" : "\(instruction!.count) chars")")
        isRefining = true
        let context = focusContext
        let generation = editGeneration
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await TextRefinementService.edit(selection.text, instruction: instruction, context: context)
                guard !Task.isCancelled, self.editGeneration == generation else { return }
                TranscriptionHistory.shared.recordSelectionEdit(
                    recordID: recordID, selection: selection.text, output: result.text, error: nil,
                    presetName: result.presetName, provider: result.provider, model: result.model,
                    context: context)
                let removal = self.editRemoval
                let app = self.previousApp
                self.refinementTask = nil
                self.finishEdit()
                self.writeEdit(result.text, over: selection, removal: removal, in: app)
            } catch {
                guard !Task.isCancelled, self.editGeneration == generation else { return }
                let type = LLMConfiguration.providerType
                TranscriptionHistory.shared.recordSelectionEdit(
                    recordID: recordID, selection: selection.text, output: "", error: error.localizedDescription,
                    presetName: nil, provider: type.rawValue, model: LLMConfiguration.model(for: type),
                    context: context)
                dlog("Edit", "rewrite failed: \(error.localizedDescription)")
                self.refinementTask = nil
                self.abortEdit(icon: "sparkles", title: "AI edit failed", detail: error.localizedDescription)
            }
        }
    }

    /// Pastes the rewrite where the selection was cut. The caret is wherever the cut left
    /// it, unless the user has moved it since — then that is where the text goes.
    private func writeEdit(_ output: String, over selection: CapturedSelection,
                           removal: EditRemoval, in app: NSRunningApplication?) {
        switch removal {
        case .removed(let original, let cutText):
            guard SelectionEdit.changes(selection.text, to: output) else {
                putBack(original, in: app)
                showStatus(icon: "checkmark", title: "Nothing to change",
                           detail: "The AI left the selected text as it was.", tint: .secondary)
                return
            }
            let text = SelectionEdit.preservingEdges(of: cutText, output)
            deliverToEditTarget(app, fallback: { PasteService.copyToClipboard(text) }) {
                dlog("Edit", "pasting the rewrite where the selection was")
                PasteService.pasteAtCursor(text)
            }
        case .notRemovable, .inPlace, .removing:
            guard SelectionEdit.changes(selection.text, to: output) else {
                showStatus(icon: "checkmark", title: "Nothing to change",
                           detail: "The AI left the selected text as it was.", tint: .secondary)
                return
            }
            PasteService.copyToClipboard(output)
            showStatus(icon: "doc.on.clipboard", title: "Copied instead of replaced",
                       detail: "\(app?.localizedName ?? "The app") wouldn't let the selected text be removed. The new version is on the clipboard.",
                       tint: .orange, duration: 8)
        }
    }

    /// Puts the cut selection back, formatting and all.
    private func putBack(_ original: [NSPasteboardItem], in app: NSRunningApplication?) {
        dlog("Edit", "putting the selected text back")
        deliverToEditTarget(app, fallback: { PasteService.copyToClipboard(items: original) }) {
            PasteService.pasteItems(original)
        }
    }

    /// Runs `paste` in the edit's app, bringing it back to the front first if it has to.
    /// With the app gone, `fallback` leaves the text on the clipboard instead.
    private func deliverToEditTarget(_ app: NSRunningApplication?, fallback: @escaping () -> Void,
                                     paste: @escaping () -> Void) {
        guard let app, !app.isTerminated else {
            fallback()
            showStatus(icon: "doc.on.clipboard", title: "The text is on the clipboard",
                       detail: "The app it came from is gone.", tint: .orange, duration: 8)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            paste()
        } else {
            PasteService.activateApp(app)
            // Blind wait, as for every paste into an app brought back to the front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: paste)
        }
    }

    /// Abandons the edit wherever it is — cancelled.
    func cancelEdit() {
        guard isEditMode else { return }
        dlog("Edit", "cancelled")
        abortEdit()
    }

    /// Ends the edit without a rewrite. Text already cut goes back where it was; `title`,
    /// when given, says why.
    private func abortEdit(icon: String = "", title: String? = nil, detail: String = "",
                           tint: Color = .orange) {
        let removal = editRemoval
        let app = previousApp
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        speechEngine.cancelRecording()
        finishEdit()
        var detail = detail
        if case .removed(let original, _) = removal {
            putBack(original, in: app)
            if title != nil { detail += " The text was put back." }
        }
        if let title {
            showStatus(icon: icon, title: title, detail: detail, tint: tint)
        }
    }

    /// Ends the edit's state and takes the overlay down; the engine is already idle.
    private func finishEdit() {
        editGeneration += 1
        editTapTimer?.cancel()
        editTapTimer = nil
        editGesture.reset()
        isRefining = false
        isEditMode = false
        editSelection = nil
        isReadingSelection = false
        editRemoval = .inPlace
        removesSelection = false
        editInstruction = .listening
        hideOverlay()
    }

    private func showOverlay() {
        // Close any existing panel first to prevent orphaned overlays
        hideOverlay()

        let panel = RecordingOverlayPanel(showsTranscript: showsLiveTranscript)
        panel.host(ObservedOverlay(speechEngine: speechEngine, appState: self, layout: panel.layout,
                                   onTranscriptHeight: { [weak panel] in panel?.setTranscriptHeight($0) },
                                   onCancel: { [weak self, weak panel] in
            if self?.isEditMode == true {
                self?.cancelEdit()
                return
            }
            self?.transcriptionWaitTask?.cancel()
            self?.transcriptionWaitTask = nil
            self?.refinementTask?.cancel()
            self?.refinementTask = nil
            self?.isRefining = false
            self?.endInlineDelivery()
            self?.speechEngine.cancelRecording()
            // Close this specific panel regardless of what overlayPanel points to
            panel?.close()
            if self?.overlayPanel === panel {
                self?.overlayPanel = nil
            }
        }))
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

        let panel = StatusOverlayPanel(above: overlayPanel.flatMap { $0.isVisible ? $0.frame : nil })
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
        // Mid-edit the Record Window would take over `previousApp` from under the edit.
        if isEditMode {
            dlog("Hotkey", "record window pressed during an edit → cancel the edit")
            cancelEdit()
            return
        }
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
        directRecordingCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, self.directRecordingPanel === panel else { return }
            self.releaseDirectRecordingEngine()
            self.removeDirectRecordingCloseObserver()
            self.directRecordingPanel = nil
        }
    }

    private func hideDirectRecordingPanel() {
        releaseDirectRecordingEngine()
        removeDirectRecordingCloseObserver()
        if let panel = directRecordingPanel {
            panel.close()
        }
        directRecordingPanel = nil
    }

    /// Lets the Record Window's engine finish what it is doing and forgets it: a live
    /// recording is stopped (its text is written to History, nothing is pasted), a
    /// transcription in flight is left to land, and an engine still *starting* is
    /// cancelled — it has no result to wait for, and forgetting it mid-start left the
    /// tap running into a session nobody would ever finish.
    private func releaseDirectRecordingEngine() {
        if let engine = directRecordingSpeechEngine {
            if engine.isRecording || engine.isPaused {
                engine.stopRecording()
            } else if engine.isStartingEngine {
                engine.cancelRecording()
            }
        }
        directRecordingSpeechEngine = nil
    }

    private func removeDirectRecordingCloseObserver() {
        if let observer = directRecordingCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            directRecordingCloseObserver = nil
        }
    }
}

/// A wrapper view that observes the SpeechEngine to update the waveform overlay
struct ObservedOverlay: View {
    @Bindable var speechEngine: SpeechEngine
    @Bindable var appState: AppState
    let layout: OverlayLayout
    let onTranscriptHeight: (CGFloat) -> Void
    let onCancel: () -> Void

    var body: some View {
        RecordingOverlayView(
            barLevels: speechEngine.barLevels,
            isLoading: speechEngine.isTranscribing || appState.isRefining,
            isPreparing: speechEngine.isStartingEngine,
            isAIMode: appState.isAIMode,
            isEditMode: appState.isEditMode,
            showsTranscript: appState.showsLiveTranscript,
            growsDown: layout.growsDown,
            transcriptHeight: layout.transcriptHeight,
            settledText: appState.showsLiveTranscript ? speechEngine.spanLayer.stableText : "",
            movingText: appState.showsLiveTranscript ? speechEngine.spanLayer.segmentProvisionalText : "",
            onTranscriptHeight: onTranscriptHeight,
            onCancel: onCancel
        )
    }
}
