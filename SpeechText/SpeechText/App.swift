// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import ServiceManagement

@main
struct SpeechTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// The Settings window is `SettingsWindow`, drawn in the setup window's frame, which
    /// a `Settings` scene cannot wear. The scene stays, empty, because an app needs one;
    /// its menu item — Settings… (⌘,), in the app menu whenever the Dock icon is shown —
    /// is replaced by one that opens our window, so the scene itself never opens.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
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

/// Lets `CustomVocabulary.ranked` count how often each term appears in History, so
/// the terms a model is sent when it cannot take them all are the ones actually used.
/// History is written on the main thread; read from anywhere else it gives nothing, and
/// the terms keep their date order.
func registerVocabularyHistory() {
    CustomVocabulary.historyTexts = {
        guard Thread.isMainThread else { return [] }
        return TranscriptionHistory.shared.records.map(\.text)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var settingsWindow: SettingsWindow?
    /// A Settings window built ahead, while the main window is open, so its Settings opens
    /// at once: building and laying one out costs about a third of a second.
    private var preparedSettingsWindow: SettingsWindow?
    private var mainWindow: MainWindow?
    private var debugLogWindow: DebugLogWindow?
    private var dockIcon: DockIconController?
    private var setupWindow: OnboardingWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened straight from the disk image: move to Applications and start again from
        // there, before this copy writes a setting, registers a login item or opens setup.
        if MainActor.assumeIsolated({ AppInstaller.moveIfRunningFromDiskImage() }) { return }

        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon(recording: false)

        // Carry the pre-rename settings over, then drop provider values left over from
        // removed engines — both before any UI reads them. The setup gate is decided in
        // between: settings a renamed install brings with it are evidence of an earlier
        // launch, but the migrations below write settings on a new install too
        // (`spokenLanguages`, always), and read after them every new install looked like
        // an old one — setup never opened, and the two permission alerts did instead.
        adoptPreRenameDefaults()
        openAPIKeyStore()
        let setupGate = decideSetupGate()
        migrateSelectedLanguageIfNeeded()
        CustomVocabulary.migrateLegacyStoreIfNeeded()
        normalizeStoredProviders()

        // Build the menu
        rebuildMenu()

        // Dictations saved to History with no network are transcribed once it is back.
        MainActor.assumeIsolated {
            OfflineRetry.shared.onTranscribed = { [weak appState] texts in
                appState?.showTranscribedOnceOnline(texts)
            }
            OfflineRetry.shared.start()
        }

        if setupGate == .show {
            // Setup asks for the microphone and Accessibility itself, on a screen that
            // says what they are for — not in two unexplained alerts at launch.
            DispatchQueue.main.async { [weak self] in self?.openSetup() }
        } else {
            // Request microphone access on launch
            appState.speechEngine.requestMicrophoneAccess { granted in
                if !granted {
                    dlog("App", "Microphone access denied")
                }
            }

            // Prompt for accessibility permission on launch if not already granted.
            // This is required for pasting text at the cursor via the inline recorder.
            if !PasteService.isAccessibilityGranted {
                PasteService.promptAccessibility()
            }
        }

        registerLocalSTT()
        registerSpellCheckedJoins()
        registerVocabularyHistory()
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
        appState.hotkeyManager.onEscape = { [weak self] in
            self?.appState.escapePressed()
            self?.updateIcon()
            self?.rebuildMenu()
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
        // Settings' Edit Prompts… asks for the main window's Prompts page the same way.
        NotificationCenter.default.addObserver(
            forName: .openMainWindowPage, object: nil, queue: .main
        ) { [weak self] note in
            self?.showMainWindow(on: (note.object as? String).flatMap(MainPage.init(rawValue:)))
        }
        // A notice's way to a Settings page — the microphone notice's Change.
        NotificationCenter.default.addObserver(
            forName: .openSettingsPage, object: nil, queue: .main
        ) { [weak self] note in
            self?.showSettings(category: note.object as? SettingsCategory)
        }

        // Auto-register as login item on first launch (default: ON) — unless setup is
        // open, whose Permissions step turns it on where the switch for it is, rather
        // than with a "Login Item Added" notification before anything was explained.
        if setupGate != .show, !UserDefaults.standard.bool(forKey: SettingsKeys.hasRegisteredLaunchAtLogin) {
            UserDefaults.standard.set(true, forKey: SettingsKeys.hasRegisteredLaunchAtLogin)
            try? SMAppService.mainApp.register()
        }
    }

    /// Whether the setup window opens at launch — see `OnboardingGate`. Read before the
    /// login item is registered below, which is one of the signs of an earlier launch.
    private func decideSetupGate() -> OnboardingGate {
        let defaults = UserDefaults.standard
        let usedBefore = defaults.bool(forKey: SettingsKeys.hasRegisteredLaunchAtLogin)
            || SettingsKeys.portable.contains { defaults.object(forKey: $0) != nil }
            || APIKeyStore.shared.hasAnyKey
        let gate = OnboardingGate.decide(
            completed: defaults.object(forKey: SettingsKeys.onboardingCompleted) as? Bool,
            hasUsedTheAppBefore: usedBefore)
        switch gate {
        case .markCompleted:
            defaults.set(true, forKey: SettingsKeys.onboardingCompleted)
            dlog("Setup", "an existing install — setup marked as done")
        case .show:
            // Written down at once: setup's own steps store settings (and the login item)
            // that would otherwise make the next launch take an unfinished setup for an
            // old install and mark it done.
            defaults.set(false, forKey: SettingsKeys.onboardingCompleted)
        case .skip:
            break
        }
        return gate
    }

    @objc private func openSetup() {
        MainActor.assumeIsolated {
            if setupWindow == nil {
                setupWindow = OnboardingWindow(appState: appState) { [weak self] in
                    self?.setupWindow = nil
                    self?.rebuildMenu()
                }
            }
            setupWindow?.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copy on the disk image that moved itself never opened History.
        guard !AppInstaller.isLeaving else { return }
        // History writes are coalesced; a record made in the last quarter second is
        // still pending here.
        TranscriptionHistory.shared.flush()
    }

    /// A click on the Dock icon with nothing on screen opens the main window — otherwise
    /// the icon the user asked for would do nothing at all when clicked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !DockIconController.hasOpenWindow() {
            openMainWindow()
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

    private static let recordingItemTag = 1
    private static let aiItemTag = 2

    /// The two recording items say what a click does now. Retitled each time the menu
    /// opens, too: the phase moves on by itself (a rewrite finishing), and a menu built
    /// while it was busy would otherwise offer to cancel a dictation that is over.
    private func updateRecordingItemTitles(in menu: NSMenu) {
        let shortcut = currentShortcutDisplayString()
        let aiShortcut = currentAIShortcutDisplayString()
        let (title, aiTitle): (String, String)
        switch appState.dictationPhase {
        case .idle:
            (title, aiTitle) = ("Start Recording (\(shortcut))", "AI Recording (\(aiShortcut))")
        case .busy:
            // Transcribing or rewriting: either item cancels.
            (title, aiTitle) = ("Cancel Dictation (\(shortcut))", "Cancel Dictation (\(aiShortcut))")
        case .starting(let ai), .recording(let ai):
            // During a dictation, the other mode's item switches it over rather than stopping it.
            let own = appState.speechEngine.isRecording ? "Stop" : "Cancel"
            (title, aiTitle) = ai
                ? ("Switch to Plain Text (\(shortcut))", "\(own) AI Recording (\(aiShortcut))")
                : ("\(own) Recording (\(shortcut))", "Switch to AI (\(aiShortcut))")
        }
        menu.item(withTag: Self.recordingItemTag)?.title = title
        menu.item(withTag: Self.aiItemTag)?.title = aiTitle
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateRecordingItemTitles(in: menu)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Which build is this? The app has no window and no About box, so the menu
        // is the only place the answer can live — and after a rebuild it is the
        // first thing worth checking.
        let versionItem = NSMenuItem(title: "SpeechText \(AppVersion.displayString)",
                                     action: #selector(copyVersion), keyEquivalent: "")
        versionItem.target = self
        versionItem.toolTip = "Click to copy this build's version"
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let mainItem = NSMenuItem(title: "Open SpeechText", action: #selector(openMainWindow), keyEquivalent: "")
        mainItem.target = self
        menu.addItem(mainItem)

        menu.addItem(.separator())

        let recordingItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
        recordingItem.target = self
        recordingItem.tag = Self.recordingItemTag
        menu.addItem(recordingItem)

        let aiItem = NSMenuItem(title: "", action: #selector(toggleAIRecording), keyEquivalent: "")
        aiItem.target = self
        aiItem.tag = Self.aiItemTag
        menu.addItem(aiItem)
        updateRecordingItemTitles(in: menu)

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

        // Setup can be run again at any time; unfinished, it picks up where it was left.
        let setupDone = UserDefaults.standard.bool(forKey: SettingsKeys.onboardingCompleted)
        let setupItem = NSMenuItem(title: setupDone ? "Set Up SpeechText..." : "Continue Setup...",
                                   action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

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
        showSettings()
    }

    /// Reached from the status menu, the app menu's Settings… and the main window, all on
    /// main. A closed window is let go, so the next one opens on General — or the page the
    /// main window asked for — with every status read afresh.
    func showSettings(category: SettingsCategory? = nil) {
        MainActor.assumeIsolated {
            if let settingsWindow {
                if let category {
                    NotificationCenter.default.post(name: .settingsShowCategory, object: category)
                }
                settingsWindow.present()
                return
            }
            if let window = preparedSettingsWindow {
                preparedSettingsWindow = nil
                settingsWindow = window
                window.present()
                if let category, category != .general {
                    NotificationCenter.default.post(name: .settingsShowCategory, object: category)
                }
                return
            }
            let window = SettingsWindow(category: category ?? .general) { [weak self] in
                self?.settingsWindow = nil
                self?.prepareSettingsWindowSoon()
            }
            settingsWindow = window
            window.present()
        }
    }

    /// Builds the next Settings window a moment after the main window has drawn — and again
    /// after Settings closes while the main window is still open — so it is read afresh
    /// for each opening, as before, only earlier.
    private func prepareSettingsWindowSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mainWindow?.isVisible == true,
                      self.settingsWindow == nil, self.preparedSettingsWindow == nil else { return }
                let window = SettingsWindow(category: .general) { [weak self] in
                    self?.settingsWindow = nil
                    self?.prepareSettingsWindowSoon()
                }
                window.contentView?.layoutSubtreeIfNeeded()
                self.preparedSettingsWindow = window
            }
        }
    }

    /// The main window: from the status menu and a click on the Dock icon. Let go when
    /// closed, like Settings, so it opens again on Home.
    @objc private func openMainWindow() {
        showMainWindow()
    }

    /// History is a page of the main window: the status menu's History…, and a notice's
    /// way to a dictation it saved, open the window on it.
    @objc private func openHistory() {
        showMainWindow(on: .history)
    }

    private func showMainWindow(on page: MainPage? = nil) {
        MainActor.assumeIsolated {
            if mainWindow == nil {
                let actions = MainWindowActions(
                    openSettings: { [weak self] category in self?.showSettings(category: category) })
                mainWindow = MainWindow(actions: actions) { [weak self] in
                    self?.mainWindow = nil
                    self?.preparedSettingsWindow = nil
                }
            }
            mainWindow?.present(page)
            prepareSettingsWindowSoon()
        }
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
    /// Posted when something (menu item, status overlay tap) wants History — a page of the
    /// main window. AppDelegate owns the window, so AppState signals rather than opening it directly.
    static let openHistoryWindow = Notification.Name("openHistoryWindow")
    /// A page of the main window, by `MainPage` raw value as the object.
    static let openMainWindowPage = Notification.Name("openMainWindowPage")
    /// The Settings window, on the `SettingsCategory` given as the object.
    static let openSettingsPage = Notification.Name("openSettingsPage")
}

// MARK: - AppState

@Observable
final class AppState {
    let speechEngine = SpeechEngine()
    let hotkeyManager = HotkeyManager()

    init() {
        speechEngine.onMicrophoneSubstituted = { [weak self] resolution in
            self?.showMicrophoneNoticeOnce(resolution)
        }
    }

    private var overlayPanel: RecordingOverlayPanel?
    private var statusPanel: StatusOverlayPanel?
    private var statusDismissItem: DispatchWorkItem?
    private var directRecordingPanel: DirectRecordingPanelWindow?
    private var directRecordingSpeechEngine: SpeechEngine?
    /// The block observer on the Record Window's `willClose`. Kept so it can be removed:
    /// `removeObserver(self, …)` does nothing for a block observer, and a leaked one from
    /// a previous panel cleared the *new* panel's references when the old one closed.
    private var directRecordingCloseObserver: NSObjectProtocol?
    /// The app the user was in when the recording started. An inline dictation's *origin*
    /// — it is pasted where it ended (`pasteDestination`), and here only when that was
    /// SpeechText's own window. The Edit shortcut and the Record Window paste here.
    var previousApp: NSRunningApplication?
    /// Where the current inline dictation goes: the app in front when the user stopped,
    /// fixed at the stop (`InlineDelivery.destination`). Every step after the stop is
    /// handed this app, not `previousApp` — the paste, the AI prompt's `<context>`,
    /// History and the trace. Nil until the stop.
    private var pasteDestination: NSRunningApplication?

    /// Setup's Try it step. While it is on screen a dictation's result goes to it
    /// instead of being pasted — the app never pastes into its own windows.
    let dictationTest = DictationTest()
    /// The current inline dictation was started from the Try it step. Captured at the
    /// start, so leaving the step mid-dictation cannot send the test's text anywhere.
    private var isTestDictation = false

    /// True when the current inline session is in AI mode — started with the AI hotkey or
    /// switched to it — so the transcription gets routed through `TextRefinementService`
    /// before pasting.
    private(set) var isAIMode = false
    /// Where the text is going: for an AI dictation, read at the stop from
    /// `pasteDestination`; for an edit, at its start from the app in front. Sent only with
    /// an AI rewrite.
    private var focusContext: FocusContext?
    /// The current recording's tier reports text while the user speaks (a stream, or
    /// Apple's on-device recogniser), so the overlay shows it. Nothing is pasted before
    /// the stop either way.
    private(set) var showsLiveTranscript = false
    /// True while the LLM is rewriting the transcription — keeps the overlay spinning.
    private(set) var isRefining = false
    private var refinementTask: Task<Void, Never>?
    /// The task parked in `waitForTranscription()`. Cancelling the inline flow cancels
    /// it too: `cancelRecording()` moves the engine off `.finishing`, which resumes the
    /// waiter, and without the cancel it would run `handleTranscriptionResult()` over
    /// the cleared texts and pop "No speech detected" for an action the user asked for.
    private var transcriptionWaitTask: Task<Void, Never>?

    /// Presses and releases of the two dictation shortcuts, and whether the one that
    /// started a dictation is still held.
    private var hotkeyGesture = DictationHotkeyGesture()

    /// Where the inline flow is, in the terms the shortcuts care about.
    var dictationPhase: DictationHotkeyGesture.Phase {
        if speechEngine.isTranscribing || isRefining { return .busy }
        if speechEngine.isStartingEngine { return .starting(ai: isAIMode) }
        if speechEngine.isRecording { return .recording(ai: isAIMode) }
        return .idle
    }

    /// Without an AI provider the AI shortcut is simply a second dictation shortcut: a
    /// dictation that ends in "AI processing skipped" every time teaches the user nothing.
    private func effectiveKey(_ key: DictationHotkey) -> DictationHotkey {
        key == .ai && !TextRefinementService.isConfigured ? .inline : key
    }

    /// A dictation shortcut went down.
    func hotkeyPressed(_ pressed: DictationHotkey) {
        // An edit's recording is an instruction, not a dictation: there is nothing for
        // a dictation shortcut to switch or stop, and the likeliest meaning of the press
        // is "not this, I want to dictate". It cancels the edit and does nothing more.
        if isEditMode {
            dlog("Hotkey", "\(pressed) pressed during an edit → cancel the edit")
            cancelEdit(.otherShortcut)
            return
        }
        if dictationTest.isBlocked && dictationPhase == .idle {
            dlog("Hotkey", "\(pressed) pressed while setup waits for the speech model → ignored")
            return
        }
        let key = effectiveKey(pressed)
        hotkeyGesture.holdToTalk = UserDefaults.standard.bool(forKey: SettingsKeys.holdToTalk)
        let phase = dictationPhase
        let action = hotkeyGesture.press(key, in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "\(key) pressed in \(phase) → \(action)")
        perform(action)
        if case .start = action, hotkeyGesture.owner != nil {
            beginHoldTip(pressed == .ai ? .ai : .inline, canSwitch: TextRefinementService.isConfigured)
        } else if hotkeyGesture.owner == nil {
            endHoldTip()
        }
    }

    /// A dictation shortcut came back up. Only acts with hold-to-talk on, and only for the
    /// shortcut that started the dictation.
    func hotkeyReleased(_ released: DictationHotkey) {
        guard !isEditMode else { return }
        let key = effectiveKey(released)
        let phase = dictationPhase
        let action = hotkeyGesture.release(key, in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "\(key) released in \(phase) → \(action)")
        perform(action)
        if hotkeyGesture.owner == nil { endHoldTip() }
        if hotkeyGesture.awaitsSecondTap {
            scheduleDictationTapTimer()
        }
    }

    /// Cancels a tapped dictation unless a second tap locks it on first.
    private var dictationTapTimer: DispatchWorkItem?

    private func scheduleDictationTapTimer() {
        dictationTapTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dictationTapTimer = nil
            let action = self.hotkeyGesture.tapWindowExpired(in: self.dictationPhase, at: ProcessInfo.processInfo.systemUptime)
            dlog("Hotkey", "dictation tap stood alone → \(action)")
            self.perform(action)
        }
        dictationTapTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationHotkeyGesture.doubleTapWindow, execute: timer)
    }

    /// The menu's items: a press with nothing held.
    func toggleRecording(aiMode: Bool = false) {
        if isEditMode {
            cancelEdit(.otherShortcut)
            return
        }
        dlog("App", "toggleRecording: isRecording=\(speechEngine.isRecording), isTranscribing=\(speechEngine.isTranscribing), isStartingEngine=\(speechEngine.isStartingEngine)")
        perform(hotkeyGesture.click(effectiveKey(aiMode ? .ai : .inline), in: dictationPhase))
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
                cancelInlineFlow(.shortcut)
            }
        case .cancel(let reason):
            cancelInlineFlow(reason)
        case .lock:
            dlog("App", "double tap — the dictation stays on hands-free")
            dictationTapTimer?.cancel()
            dictationTapTimer = nil
        case .ignore:
            break
        }
    }

    /// The dictation carries on in the other mode. What is said stays one dictation;
    /// only its handling at the stop changes — nothing has been pasted yet, in either
    /// direction, so there is nothing to take back.
    private func switchMode(toAI: Bool) {
        dlog("App", "switching the dictation to \(toAI ? "AI" : "plain text")")
        isAIMode = toAI
        DictationTraceRecorder.record(.modeSwitch, text: toAI ? "ai" : "inline")
    }

    /// Aborts recording, transcription and any in-flight LLM call, drops the overlay, and
    /// says so: no cancel is silent (#72).
    func cancelInlineFlow(_ reason: DictationCancelReason) {
        // Written at the stop, before the LLM: a cancel during the rewrite leaves it there.
        let savedInHistory = isRefining && speechEngine.lastRecordID != nil
        dlog("App", "cancelling mid-flight (\(reason)\(savedInHistory ? ", the transcript stays in History" : ""))")
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        isRefining = false
        pasteDestination = nil
        DictationTraceRecorder.current = nil
        speechEngine.cancelRecording()
        hideOverlay()
        let notice = reason.notice(savedInHistory: savedInHistory)
        showStatus(icon: "xmark.circle", title: notice.title, detail: notice.detail, tint: .secondary,
                   duration: savedInHistory ? 5 : 3)
    }

    private func startRecording() {
        isTestDictation = dictationTest.isActive
        let front = NSWorkspace.shared.frontmostApplication
        if isTestDictation {
            // The result goes to the setup window; there is no app to paste into.
            previousApp = nil
            dictationTest.began(ai: isAIMode)
        } else if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        pasteDestination = nil
        focusContext = nil
        let locale = resolvedLocale()
        // The same settings the engine snapshots a moment later, read the same way.
        showsLiveTranscript = RecordingConfiguration.current(locale: locale).hasLiveText
        dlog("App", "startRecording: previousApp=\(previousApp?.localizedName ?? "nil"), locale=\(locale), aiMode=\(isAIMode), liveTranscript=\(showsLiveTranscript)")

        speechEngine.recordsEmptyOutcomes = true
        beginTrace()
        showOverlay()

        // A start that fails (microphone refused, no input device, a stream that could
        // not open) never reaches a stop, and the "preparing" overlay used to sit there
        // until the next hotkey press.
        speechEngine.onStartFailure = { [weak self] message in
            self?.handleStartFailure(message)
        }
        // Nor did a recogniser that failed before any text: the overlay listened on until
        // the user stopped (#69). The engine has stopped by now; the result is the stop's.
        speechEngine.onRecognitionFailure = { [weak self] message in
            self?.handleRecognitionFailure(message)
        }
        // Retried by itself once the network is back — but not a test dictation, whose
        // result belongs to the setup window that has long moved on by then.
        speechEngine.onSavedOffline = isTestDictation ? nil : { id in MainActor.assumeIsolated { OfflineRetry.shared.enqueue(id) } }
        speechEngine.startRecording(locale: locale)
    }

    /// The engine ended the dictation itself: the rest of an ordinary stop, without a
    /// second engine stop, and without a paste target or a focus context — the result
    /// is a failure, which goes to neither.
    private func handleRecognitionFailure(_ message: String) {
        dlog("App", "recognition failed before any text — ending the dictation: \(message)")
        DictationTraceRecorder.record(.stop)
        waitForTranscription()
    }

    private func handleStartFailure(_ message: String) {
        dlog("App", "startRecording failed: \(message)")
        DictationTraceRecorder.current = nil
        hideOverlay()
        showStatus(
            icon: "exclamationmark.triangle.fill",
            title: "Couldn't start recording",
            detail: friendlySTTError(message),
            tint: .orange
        )
    }

    /// Starts this dictation's trace, when Debug Log › Record traces is on.
    private func beginTrace() {
        DictationTraceRecorder.current = DictationTraceRecorder.isEnabled
            ? DictationTraceRecorder(setup: DictationTrace.Setup(
                aiMode: isAIMode,
                removesDisfluencies: UserDefaults.standard.object(forKey: SettingsKeys.removeDisfluencies) as? Bool ?? true,
                dashStyle: .current,
                app: previousApp?.localizedName))
            : nil
    }

    private func stopRecording() {
        dlog("App", "stopRecording")
        // First, while the app the user stopped in is certainly the one in front.
        choosePasteDestination()
        DictationTraceRecorder.record(.stop)
        speechEngine.stopRecording()
        // After the engine stop, not before: these are round trips to another process, and
        // only the LLM pass reads the answer. The mode cannot change past this point —
        // every press while the stop is transcribing cancels.
        if isAIMode {
            readFocusContext(of: pasteDestination)
        }
        waitForTranscription()
    }

    /// Fixes where this dictation goes: the app in front now, unless that is SpeechText
    /// itself (`InlineDelivery.destination`). A test dictation goes nowhere — its result
    /// belongs to the setup window.
    private func choosePasteDestination() {
        let front = NSWorkspace.shared.frontmostApplication
        pasteDestination = isTestDictation ? nil : InlineDelivery.destination(
            front: front,
            frontIsSpeechText: front?.bundleIdentifier == Bundle.main.bundleIdentifier,
            origin: previousApp)
        let destination = pasteDestination?.localizedName ?? "nil"
        if pasteDestination?.processIdentifier != previousApp?.processIdentifier {
            dlog("App", "paste target: \(destination) (started in \(previousApp?.localizedName ?? "nil"))")
        } else {
            dlog("App", "paste target: \(destination)")
        }
        DictationTraceRecorder.recordDestination(pasteDestination?.localizedName)
    }

    /// Reads what the AI prompt is told about where the text is going. Never with a nil
    /// app: `readFocusContext(in: nil)` would describe whatever is frontmost.
    private func readFocusContext(of app: NSRunningApplication?) {
        focusContext = app.flatMap { PasteService.readFocusContext(in: $0) }
        if let focusContext {
            // The window title stays out of the system log — it can be a mail subject.
            dlog("Refine", "focus context: \(focusContext.appName ?? "?") (\(focusContext.bundleID ?? "?")), window title \(focusContext.windowTitle == nil ? "absent" : "present")")
        }
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
        dlog("App", "handleTranscriptionResult: text=\(text.count) chars, destination=\(pasteDestination?.localizedName ?? "nil"), aiMode=\(isAIMode)")

        let result = InlineDelivery.stopResult(finalText: text,
                                               failed: speechEngine.errorMessage != nil,
                                               aiMode: isAIMode,
                                               recordingText: speechEngine.spanLayer.text)
        if isTestDictation, reportTestResult(result) {
            finishTrace()
            return
        }
        switch result {
        case .failed(let partial):
            // A failed transcription used to end here silently — the user just saw nothing
            // happen and lost everything they said. Always surface it.
            let rawError = speechEngine.errorMessage ?? ""
            dlog("App", "handleTranscriptionResult: error — \(rawError)")
            hideOverlay()
            if let recordID = speechEngine.offlineRecordID {
                // Not an error to read: nothing is lost, it is waiting in History.
                showSavedOffline(recordID)
            } else {
                showStatus(
                    icon: "exclamationmark.triangle.fill",
                    title: "Transcription failed",
                    detail: friendlySTTError(rawError),
                    tint: .orange
                )
            }
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

        case .paste(let text):
            hideOverlay()
            recordApps()
            deliver(text)

        case .refine(let aiInput):
            recordApps()
            // The trace is finished once the rewrite has been delivered.
            refine(aiInput)
            return
        }
        finishTrace()
    }

    /// Writes where the dictation started and where it is going to History — only for one
    /// that is about to be pasted: a failure or an empty result went nowhere.
    private func recordApps() {
        guard !isTestDictation, let id = speechEngine.lastRecordID else { return }
        TranscriptionHistory.shared.recordApps(id: id, origin: previousApp?.localizedName,
                                               destination: pasteDestination?.localizedName)
    }

    /// Hands a test dictation's result to setup instead of pasting it or raising a notice:
    /// the Try it step says in its own words what happened. False for an AI rewrite,
    /// which `refine` reports once the model has answered.
    private func reportTestResult(_ result: InlineDelivery.StopResult) -> Bool {
        let outcome: DictationTest.Outcome
        switch result {
        case .failed:
            outcome = .failed(friendlySTTError(speechEngine.errorMessage ?? ""))
        case .noSpeech:
            outcome = .nothingHeard
        case .paste(let text):
            outcome = .typed(text)
        case .refine:
            return false
        }
        hideOverlay()
        dictationTest.finished(outcome, ai: isAIMode)
        return true
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
            deliver(aiInput)
            finishTrace()
            return
        }

        // Keep the overlay up (now in its loading state) while the LLM rewrites the text.
        isRefining = true
        let recordID = speechEngine.lastRecordID
        let context = focusContext
        let isTest = isTestDictation
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
                        context: context, usage: result.usage, latency: result.latency
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
                if isTest {
                    self.isRefining = false
                    self.refinementTask = nil
                    self.hideOverlay()
                    self.dictationTest.rewritten(said: aiInput, result: .failure(error))
                    return
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
            if isTest {
                self.dictationTest.rewritten(said: aiInput, result: .success(output))
                self.finishTrace()
                return
            }
            self.deliver(output)
            self.finishTrace()
        }
    }

    /// Pastes into the app the dictation ended in (`pasteDestination`), falling back to
    /// the Record Window when that isn't possible.
    private func deliver(_ dictation: String) {
        // A trailing space, so a dictation continued into the same field does not start
        // glued to this one — every path upstream trims. It is added here, at the paste,
        // so History and the span layer keep the transcript as it was recognised, and before the trace is written so a recorded dictation
        // replays into the text that really went out — which the Record Window fallback
        // below inherits, where a trailing space costs nothing.
        let text = dictation + " "
        DictationTraceRecorder.record(.stopPaste, text: text)
        if !PasteService.isAccessibilityGranted {
            dlog("App", "deliver: no accessibility, showing record panel")
            PasteService.promptAccessibility()
            showDirectRecordingPanel(withText: text)
            return
        }

        // The origin only when the stop chose nothing — the engine ended the recording on
        // its own, which does not pass through `stopRecording`.
        guard let app = pasteDestination ?? previousApp else {
            dlog("App", "deliver: no destination, showing record panel")
            showDirectRecordingPanel(withText: text)
            return
        }

        // Paste into the destination. If the focused element is a known non-text role
        // (button, table, list, etc.), fall back to the Record Window instead.
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
    /// `editSelection` was read after the instruction ended, so it is the selection the
    /// edit works on (#73); otherwise it is read again before the cut.
    private var selectionIsCurrent = false
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
        if case .start = action, editGesture.isHeld, isEditMode {
            beginHoldTip(.edit, canSwitch: false)
        } else if !editGesture.isHeld {
            endHoldTip()
        }
    }

    /// The Edit shortcut came back up.
    func editHotkeyReleased() {
        guard isEditMode else { return }
        let phase = editPhase
        let action = editGesture.release(in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "edit released in \(phase) → \(action)")
        perform(action)
        if !editGesture.isHeld { endHoldTip() }
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
            speechEngine.onRecognitionFailure = nil
            speechEngine.cancelRecording()
            editInstruction = .ready(nil, recordID: nil)
            removesSelection = true
            advanceEdit()
        case .cancel(let reason):
            cancelEdit(reason)
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
        selectionIsCurrent = false
        isReadingSelection = true
        editRemoval = .inPlace
        removesSelection = false
        editInstruction = .listening
        // Nothing of the instruction is ever pasted, and it is not traced.
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
        // An instruction transcribed later has no selection left to apply to.
        speechEngine.onSavedOffline = nil
        speechEngine.onStartFailure = { [weak self] message in
            guard let self, self.isEditMode, self.editGeneration == generation else { return }
            dlog("Edit", "microphone failed to start: \(message)")
            self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't start recording",
                           detail: self.friendlySTTError(message))
        }
        // The recogniser failed before any of the instruction was heard, and the engine
        // stopped. Nothing has been cut yet — that waits for the instruction to end — so
        // the edit just ends, once the stop has written its History row.
        speechEngine.onRecognitionFailure = { [weak self] message in
            guard let self, self.isEditMode, self.editGeneration == generation else { return }
            dlog("Edit", "recognition failed before any instruction: \(message)")
            self.transcriptionWaitTask?.cancel()
            self.transcriptionWaitTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.speechEngine.awaitTranscription()
                guard !Task.isCancelled, self.isEditMode, self.editGeneration == generation else { return }
                self.transcriptionWaitTask = nil
                self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't hear the instruction",
                               detail: self.friendlySTTError(message))
            }
        }
        // Saying nothing is a request to polish, and the edit writes its own record.
        speechEngine.recordsEmptyOutcomes = false
        speechEngine.startRecording(locale: locale)
        focusContext = PasteService.readFocusContext(in: front)
    }

    private func selectionRead(_ read: PasteService.SelectionRead) {
        isReadingSelection = false
        // Read after the instruction was already over: this is the selection at the
        // send, and needs no second read.
        selectionIsCurrent = removesSelection
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

    /// The instruction is over: the selection is read again (#73) — the text selected
    /// *now* is the one rewritten, whatever was selected at the first press — and cut, so
    /// nothing the user does while the LLM works can make the rewrite land on the wrong
    /// text. The rewrite is then pasted at the caret the cut leaves.
    private func takeSelection(_ selection: CapturedSelection) {
        guard !selectionIsCurrent else {
            removeSelection(selection)
            return
        }
        // Held here so `advanceEdit` does not start a second read meanwhile.
        editRemoval = .removing
        let generation = editGeneration
        PasteService.readSelection(in: previousApp) { [weak self] read in
            DispatchQueue.main.async {
                guard let self, self.isEditMode, self.editGeneration == generation else { return }
                self.selectionIsCurrent = true
                var current: CapturedSelection?
                if case .selected(let now) = read { current = now }
                switch SelectionEdit.target(read: selection, current: current) {
                case .nothingSelected:
                    self.abortEdit(icon: "character.cursor.ibeam", title: "No text selected",
                                   detail: "Nothing was selected when the instruction ended. Nothing was edited.",
                                   tint: .secondary)
                case .tooLong:
                    self.abortEdit(icon: "text.badge.xmark", title: "Selection too long",
                                   detail: "Select up to \(SelectionEdit.maxCharacters.formatted()) characters to edit with AI.")
                case .unchanged(let now):
                    self.editSelection = now
                    self.removeSelection(now)
                case .changed(let now):
                    dlog("Edit", "the selection changed while the instruction was spoken — editing the one selected now (\(now.text.count) chars, was \(selection.text.count))")
                    self.editSelection = now
                    self.removeSelection(now)
                }
            }
        }
    }

    /// Cuts the selection, and checks that what was cut is what was read: a click
    /// elsewhere since then would otherwise have taken other text out of the document.
    private func removeSelection(_ selection: CapturedSelection) {
        editRemoval = .removing
        let generation = editGeneration
        var confirmed = false
        if let record = selection.record, let app = previousApp {
            switch PasteService.select(record, in: app) {
            case .changed:
                abortEdit(icon: "text.badge.xmark", title: "Couldn't find the selection again",
                          detail: "The selected words aren't where they were read. Nothing was edited.")
                return
            case .selected: confirmed = true
            case .unconfirmed: break
            }
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
                guard SelectionEdit.cutMatches(text, selection: selection.text, selectionConfirmed: confirmed) else {
                    dlog("Edit", "cut \(text.count) chars that are not the selection (read \(selection.record == nil ? "with ⌘C" : "through AX")) — putting them back: cut \(String(text.prefix(60)).debugDescription), read \(String(selection.text.prefix(60)).debugDescription)")
                    PasteService.pasteItems(items)
                    self.abortEdit(icon: "text.badge.xmark", title: "Couldn't confirm the selection",
                                   detail: "What was cut wasn't the text that was read, so it was put back. Nothing was edited.")
                    return
                }
                let source = SelectionEdit.cutSource(text)
                if source != selection.text {
                    dlog("Edit", "the cut differs from the text read\(confirmed ? "" : " only in markup or spacing") — rewriting the cut (\(source.count) chars, read \(selection.text.count))")
                    self.editSelection = CapturedSelection(text: source, record: selection.record)
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
                    context: context, usage: result.usage, latency: result.latency)
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

    /// Abandons the edit wherever it is — cancelled, and says so (#72, #73).
    func cancelEdit(_ reason: EditCancelReason) {
        guard isEditMode else { return }
        var textPutBack = false
        if case .removed = editRemoval { textPutBack = true }
        dlog("Edit", "cancelled (\(reason))\(textPutBack ? ", putting the cut text back" : "")")
        let notice = reason.notice(textPutBack: textPutBack)
        abortEdit(icon: "xmark.circle", title: notice.title, detail: notice.detail, tint: .secondary,
                  notesPutBack: false)
    }

    /// Ends the edit without a rewrite. Text already cut goes back where it was; `title`,
    /// when given, says why.
    private func abortEdit(icon: String = "", title: String? = nil, detail: String = "",
                           tint: Color = .orange, notesPutBack: Bool = true) {
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
            if title != nil, notesPutBack { detail += " The text was put back." }
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
        selectionIsCurrent = false
        editRemoval = .inPlace
        removesSelection = false
        editInstruction = .listening
        hideOverlay()
        if !heldOnlineTexts.isEmpty {
            let texts = heldOnlineTexts
            heldOnlineTexts = []
            showTranscribedOnceOnline(texts)
        }
    }

    private func showOverlay() {
        // Close any existing panel first to prevent orphaned overlays
        hideOverlay()

        let panel = RecordingOverlayPanel(showsTranscript: showsLiveTranscript)
        panel.host(ObservedOverlay(speechEngine: speechEngine, appState: self, layout: panel.layout,
                                   onTranscriptHeight: { [weak panel] in panel?.setTranscriptHeight($0) },
                                   onCancel: { [weak self, weak panel] in
            if self?.isEditMode == true {
                self?.cancelEdit(.closeButton)
                return
            }
            self?.cancelInlineFlow(.closeButton)
            // A stale panel, one `overlayPanel` no longer points to, is closed too.
            panel?.close()
        }))
        panel.orderFrontRegardless()
        overlayPanel = panel
        updateEscapeShortcut()
    }

    /// ⎋ is ours only while the overlay is up, and only if the user asked for it.
    private func updateEscapeShortcut() {
        let wanted = overlayPanel != nil && UserDefaults.standard.bool(forKey: SettingsKeys.escapeCancelsDictation)
        hotkeyManager.setEscapeShortcut(active: wanted)
    }

    /// ⎋, while the overlay is up: what its ✕ does.
    func escapePressed() {
        dlog("Hotkey", "⎋ → cancel")
        if isEditMode {
            cancelEdit(.escape)
        } else {
            cancelInlineFlow(.escape)
        }
    }

    private func hideOverlay() {
        endHoldTip()
        overlayPanel?.close()
        overlayPanel = nil
        updateEscapeShortcut()
    }

    // MARK: - Hold tip (#79)

    /// The shortcut whose letter holds the current hold recording, while it does.
    private var holdTipAction: ShortcutAction?
    private var holdTipStage: HoldTip.Stage = .none
    /// During the last hold recording the modifiers were let go with the letter still
    /// down — the tip was followed. Kept after the recording, for setup's practice step.
    private(set) var holdTipFollowed = false
    private var holdTipTimer: Timer?
    private var holdTipPanel: HoldTipPanel?
    private var holdTipObservers: [Any] = []

    /// A hold recording started: watch whether the modifiers are let go, and show the
    /// tip while the user has yet to learn that they may be.
    private func beginHoldTip(_ action: ShortcutAction, canSwitch: Bool) {
        endHoldTip()
        holdTipAction = action
        holdTipFollowed = false
        let count = UserDefaults.standard.integer(forKey: SettingsKeys.holdTipFollowedCount)
        // Setup's Try it teaches the same thing on its own screen.
        holdTipStage = dictationTest.isActive ? .none : HoldTip.stage(count: count, canSwitch: canSwitch)
        let keys = shortcutKeys(shortcutText(for: action))
        holdTipTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let action = self.holdTipAction, !self.holdTipFollowed else { return }
            if modifiersOfHeldShortcutLetGo(keys: keys, letterDown: HeldShortcuts.shared.down.contains(action)) {
                self.holdTipFollowed = true
                dlog("Hotkey", "hold: modifiers let go, \(action.title) still held")
                self.refreshHoldTipPanel()
            }
        }
        guard holdTipStage != .none else { return }
        // Not for a tap: a lone tap cancels, and a tip that flashed up for it would be noise.
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationHotkeyGesture.tapThreshold) { [weak self] in
            guard let self, self.holdTipAction == action, self.holdTipPanel == nil else { return }
            self.showHoldTipPanel()
        }
        dlog("Hotkey", "hold tip: \(holdTipStage), count \(count)")
    }

    private func showHoldTipPanel() {
        guard let overlay = overlayPanel else { return }
        let panel = HoldTipPanel()
        holdTipPanel = panel
        refreshHoldTipPanel()
        panel.place(beside: overlay.frame)
        panel.orderFrontRegardless()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            holdTipObservers.append(center.addObserver(forName: name, object: overlay, queue: .main) { [weak self, weak overlay] _ in
                guard let overlay else { return }
                self?.holdTipPanel?.place(beside: overlay.frame)
            })
        }
    }

    private func refreshHoldTipPanel() {
        guard let panel = holdTipPanel, let action = holdTipAction else { return }
        let other: ShortcutAction? = switch action {
        case .inline: .ai
        case .ai: .inline
        case .edit, .recordWindow: nil
        }
        panel.contentView = NSHostingView(rootView: HoldTipView(action: action, stage: holdTipStage,
                                                                other: other, followed: holdTipFollowed))
    }

    /// The hold is over, however it ended: the tip goes, and a followed tip counts.
    private func endHoldTip() {
        guard holdTipAction != nil else { return }
        holdTipTimer?.invalidate()
        holdTipTimer = nil
        for observer in holdTipObservers { NotificationCenter.default.removeObserver(observer) }
        holdTipObservers = []
        holdTipPanel?.close()
        holdTipPanel = nil
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: SettingsKeys.holdTipFollowedCount)
        let next = HoldTip.count(after: count, stage: holdTipStage, followed: holdTipFollowed)
        if next != count { defaults.set(next, forKey: SettingsKeys.holdTipFollowedCount) }
        holdTipAction = nil
        holdTipStage = .none
    }

    // MARK: - No connection

    /// A dictation that could not be transcribed for want of a network. Its audio is in
    /// History, so the notice says where it is instead of reading like a loss, and offers
    /// the retry. Stays up longer than a notice with nothing to act on.
    private func showSavedOffline(_ recordID: UUID) {
        showStatus(
            icon: "wifi.slash",
            title: "No connection — saved to History",
            detail: "It will be transcribed once you're back online.",
            tint: .orange,
            duration: 15,
            action: StatusOverlayAction(title: "Retry") { [weak self] in
                self?.retrySavedOffline(recordID)
            }
        )
    }

    private func retrySavedOffline(_ recordID: UUID) {
        showStatus(icon: "arrow.clockwise", title: "Retrying…", detail: nil, tint: .secondary,
                   duration: STTTuning.batchResourceTimeoutSeconds)
        Task { @MainActor [weak self] in
            let result = await HistoryRetry.shared.retry(recordID)
            self?.reportRetry(result, recordID: recordID)
        }
    }

    /// What a retry of a saved recording came to. A result goes to the clipboard, never
    /// into an app: by the time it lands the user may be typing somewhere else entirely.
    private func reportRetry(_ result: HistoryRetry.Result, recordID: UUID) {
        switch result {
        case .succeeded(let text):
            PasteService.copyToClipboard(text)
            showStatus(icon: "doc.on.clipboard", title: "Transcribed — copied to the clipboard",
                       detail: text, tint: Semantic.confirmation, duration: 8)
        case .offline:
            showSavedOffline(recordID)
        case .failed(let error):
            showStatus(icon: "exclamationmark.triangle.fill", title: "Retry failed",
                       detail: friendlySTTError(error), tint: .orange)
        case .alreadyRunning:
            hideStatus()
        }
    }

    /// Texts transcribed once the network came back while an edit was running, held
    /// until it ends.
    private var heldOnlineTexts: [String] = []

    /// Dictations saved offline and transcribed once the network came back: to the
    /// clipboard, oldest first, as one write — never into the app in front. Held while an
    /// edit runs: it reads the selection through the clipboard, and a write in the middle
    /// of that ⌘C would make it abort.
    func showTranscribedOnceOnline(_ texts: [String]) {
        guard !isEditMode else {
            heldOnlineTexts += texts
            return
        }
        PasteService.copyToClipboard(texts.joined(separator: "\n\n"))
        // The title is the width of the notice (measured: 221 of 272 pt); the count goes
        // in the detail, where a second line is allowed.
        let detail = texts.count == 1 ? texts[0] : "\(texts.count) dictations, oldest first."
        showStatus(icon: "doc.on.clipboard", title: "Back online — copied to the clipboard",
                   detail: detail, tint: Semantic.confirmation, duration: 10)
    }

    // MARK: - Microphone

    /// The first time Automatic records from the Mac's microphone instead of Bluetooth
    /// headphones, a notice says so and where to change it — then never again. Not
    /// during setup's Try it, whose own screen is what the user is reading.
    private func showMicrophoneNoticeOnce(_ resolution: MicrophoneResolution) {
        let defaults = UserDefaults.standard
        guard !isTestDictation, !defaults.bool(forKey: SettingsKeys.microphoneNoticeShown),
              let device = resolution.device, let avoided = resolution.avoided else { return }
        defaults.set(true, forKey: SettingsKeys.microphoneNoticeShown)
        showStatus(icon: "mic", title: "Recording with \(device.name)",
                   detail: "So \(avoided.name) keeps playing at full quality.",
                   tint: .secondary, duration: 8,
                   action: StatusOverlayAction(title: "Change") {
                       NotificationCenter.default.post(name: .openSettingsPage, object: SettingsCategory.speech)
                   })
    }

    // MARK: - Status Overlay

    func showStatus(icon: String, title: String, detail: String?, tint: Color, duration: TimeInterval = 5,
                    action: StatusOverlayAction? = nil) {
        hideStatus()

        let panel = StatusOverlayPanel(above: overlayPanel.flatMap { $0.isVisible ? $0.frame : nil })
        panel.contentView = NSHostingView(rootView: StatusOverlayView(
            icon: icon,
            title: title,
            detail: detail,
            tint: tint,
            action: action,
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
            cancelEdit(.otherShortcut)
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
        engine.onSavedOffline = { id in MainActor.assumeIsolated { OfflineRetry.shared.enqueue(id) } }
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
