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

    /// e.g. `1.0 (build 47 · a18a7d1 · 2026-09-16 14:20)`, or `1.0 (dev)`.
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
        registerLocalSTT()
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

        let quitItem = NSMenuItem(title: "Quit SpeechText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
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
    /// Where an AI dictation is going, read when its recording started. Nil outside AI
    /// mode and when the user turned the setting off.
    private var focusContext: FocusContext?
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

    /// Which sink this recording is delivering into. Decided once, when the recording
    /// starts, and never revisited: a tier that changed halfway would mean text issued
    /// under one set of rules being corrected under another.
    private var deliveryTier: DeliveryTier = .c
    /// What has actually been pasted into the target app during this recording — the
    /// sink's own record, not the engine's. The stop subtracts it from the authoritative
    /// text so a dictation is never pasted twice.
    private var inlineLedger = InsertionLedger()
    /// Spans waiting their turn, and whether one is in flight. Pastes are serialised:
    /// two ⌘V in flight at once race over the pasteboard, and the second would stage its
    /// text before the first had been read.
    private var spanQueue: [TranscriptSpan] = []
    private var isDeliveringSpan = false
    /// The field this recording delivers into, taken when the tier is decided. The stop's
    /// correction runs only while this is still the focused element of the app in front:
    /// the tier was decided for this field, not for whatever has focus by the stop.
    private var deliveryElement: AXUIElement?

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
        endInlineDelivery()
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

        beginDeliveryPlan()
        showOverlay()

        let locale = resolvedLocale()
        speechEngine.startRecording(locale: locale)

        // After the engine start, not before: nothing reads it until the stop.
        focusContext = isAIMode && FocusContext.isEnabled
            ? PasteService.readFocusContext(in: previousApp)
            : nil
        if let focusContext {
            // The window title stays out of the system log — it can be a mail subject.
            dlog("Refine", "focus context: \(focusContext.appName ?? "?") (\(focusContext.bundleID ?? "?")), window title \(focusContext.windowTitle == nil ? "absent" : "present")")
        }
    }

    // MARK: - Delivering while the user is still speaking

    /// Decides the tier for this recording and wires the engine up to it.
    ///
    /// An AI dictation with message sending on is Tier C: it may turn out to be a
    /// message, and that is only known once the LLM has answered. Nothing is lost by
    /// assuming it — AI mode buffers in every tier anyway, because the rewrite at the
    /// stop replaces the whole text.
    private func beginDeliveryPlan() {
        spanQueue = []
        isDeliveringSpan = false
        inlineLedger.clear()

        let mayBecomeMessage = isAIMode
            && UserDefaults.standard.bool(forKey: SettingsKeys.messageSendingEnabled)
        deliveryTier = .resolve(isMessageDelivery: mayBecomeMessage,
                                isOwnSurface: false,
                                probe: PasteService.probeFocusedText(in: previousApp))

        let aiDraft = UserDefaults.standard.bool(forKey: SettingsKeys.aiDraftWhileSpeaking)
        let progressive = deliveryTier.deliversDuringRecording(aiMode: isAIMode, aiDraft: aiDraft)
        dlog("Span", "tier \(deliveryTier) for \(previousApp?.localizedName ?? "nil") — \(progressive ? "delivering during the recording" : "buffering until the stop")")

        speechEngine.onSpansCommitted = progressive
            ? { [weak self] spans in self?.enqueueSpans(spans) }
            : nil
        deliveryElement = progressive && deliveryTier.recordsRanges
            ? PasteService.focusedElement(of: previousApp)
            : nil
        speechEngine.onFinalize = { [weak self] input in self?.finalizeDelivery(input) }
    }

    /// The finalizing pass: what the app was given during the recording is brought in
    /// line with the authoritative text by one write, or left exactly as it is. Runs
    /// before the engine goes idle, so `handleTranscriptionResult` sees the ledger as the
    /// pass left it — after a correction there is nothing more to paste.
    private func finalizeDelivery(_ input: SpeechEngine.FinalizeInput) {
        // An AI draft is not corrected to the raw transcript first: that would be two
        // writes where one will do. `deliverAIResult` replaces it once the rewrite is in.
        guard !isAIMode else { return }
        let decision = FinalizePass.decide(ledger: inlineLedger, authoritative: input.text,
                                           tier: deliveryTier, hasFrozenSpans: input.hasFrozenSpans)
        dlog("Span", "finalize: \(decision), tier \(deliveryTier)")

        let applied: Bool
        switch decision {
        case .nothingDelivered, .extend:
            // The stop's ordinary paste is the one write.
            return
        case .leave:
            applied = false
        case .replace:
            applied = correctDeliveredText(to: input.text)
        }
        if let id = input.recordID {
            TranscriptionHistory.shared.recordCorrection(id: id, applied: applied)
        }
    }

    private func correctDeliveredText(to text: String) -> Bool {
        // A paste still in flight has not reached the ledger: the plan would replace the
        // text before it and leave it standing after the correction — the words twice.
        guard !isDeliveringSpan else {
            dlog("Span", "finalize: a delivery is still landing — not correcting")
            return false
        }
        // The tier is checked again: it was decided for one field of one app.
        guard let app = previousApp, let element = deliveryElement,
              PasteService.isStillFocused(element, in: app) else {
            dlog("Span", "finalize: the app or the focused field changed since the recording started — not correcting")
            return false
        }
        return PasteService.replaceLastInsertions(ledger: &inlineLedger, with: text, in: app)
    }

    /// Stops offering spans. The ledger is kept: the stop still has to know what the
    /// app was given so it can hand over the rest and not the whole thing again.
    private func stopOfferingSpans() {
        speechEngine.onSpansCommitted = nil
        spanQueue = []
    }

    /// The recording was abandoned. Nothing more goes out — including anything already
    /// queued — and the ledger goes with it. Text already pasted stays where it is:
    /// un-inserting it into a foreign app is not possible.
    private func endInlineDelivery() {
        stopOfferingSpans()
        speechEngine.onFinalize = nil
        deliveryElement = nil
        inlineLedger.clear()
    }

    private func enqueueSpans(_ spans: [TranscriptSpan]) {
        spanQueue.append(contentsOf: spans)
        drainSpanQueue()
    }

    /// Pastes one emission's worth of spans, then the next. Everything ready at once
    /// goes in a single ⌘V: one paste is one race with the target app instead of
    /// several, and the ranges still come out per span whenever the app stored the text
    /// exactly as it was handed it.
    private func drainSpanQueue() {
        guard !isDeliveringSpan, !spanQueue.isEmpty else { return }

        let spans = spanQueue
        spanQueue = []

        // Only into the app the recording was started in, and only while it is still the
        // one in front: the user may have switched away mid-dictation, and text pasted
        // into whatever they switched to is worse than text delivered late. Nothing is
        // recorded in the ledger, so the stop delivers these words itself.
        guard PasteService.isAccessibilityGranted,
              let app = previousApp,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            dlog("Span", "not delivering now — the target app is not in front; the stop will")
            return
        }

        let texts = spans.map(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        let joined = texts.joined(separator: " ")
        // A space between this delivery and the last, the way the spans join.
        let payload = inlineLedger.isEmpty ? joined : " " + joined

        isDeliveringSpan = true
        PasteService.pasteAtCursor(payload) { [weak self] landing in
            guard let self else { return }
            self.isDeliveringSpan = false
            self.recordDelivery(of: spans, texts: texts, payload: payload, landing: landing)
            self.drainSpanQueue()
        }
    }

    /// Writes what went out into the ledger. Per span where the app stored exactly what
    /// it was handed — those ranges are what the finalizing pass replaces through — and
    /// as one untracked piece otherwise, which still answers what the stop asks of the
    /// ledger (what has this app already been given?) but can never be corrected.
    private func recordDelivery(of spans: [TranscriptSpan], texts: [String],
                                payload: String, landing: PasteService.PasteLanding?) {
        let joined = texts.joined(separator: " ")

        // Per span only when the app stored exactly what it was handed. Anything else —
        // it normalised the text, or the landing could not be read — and the offsets
        // would be fiction, so it goes down as one untracked piece instead.
        guard let landing, deliveryTier.recordsRanges, landing.text == payload else {
            if landing == nil {
                dlog("Span", "delivered \(spans.map(\.id.description).joined(separator: " ")), landing unknown")
            }
            inlineLedger.insert(span: nil, range: NSRange(location: NSNotFound, length: 0), text: joined)
            return
        }

        // The payload may open with the space that separates this delivery from the last.
        var location = landing.range.location + (payload as NSString).length - (joined as NSString).length
        for (span, text) in zip(spans, texts) {
            let length = (text as NSString).length
            inlineLedger.insert(span: span.id,
                                range: NSRange(location: location, length: length),
                                text: text)
            location += length + 1 // the separating space
        }
    }

    /// What the stop still has to paste, with everything already delivered taken off the
    /// front. The deciding is `InsertionLedger.remainder`; this logs what it decided.
    private func undeliveredRemainder(of authoritative: String) -> String? {
        let delivered = inlineLedger.deliveredText
        guard !delivered.isEmpty else { return authoritative }

        guard let remainder = inlineLedger.remainder(of: authoritative) else {
            dlog("Span", "final text does not extend the \(delivered.count) chars already delivered — delivering nothing more")
            return nil
        }
        dlog("Span", "already delivered \(delivered.count) chars; \(remainder.count) left to paste")
        return remainder
    }

    private func stopRecording() {
        dlog("App", "stopRecording")
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
            dlog("App", "waitForTranscription: done (\(String(format: "%.2f", Date().timeIntervalSince(started)))s)")
            handleTranscriptionResult()
        }
    }

    private func handleTranscriptionResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("App", "handleTranscriptionResult: text=\(text.count) chars, previousApp=\(previousApp?.localizedName ?? "nil"), aiMode=\(isAIMode)")

        // Spans pasted while the user was still speaking are already in the document.
        // `finalizeDelivery` has already corrected them where it could, which leaves
        // nothing here. Nil means the final text still disagrees with them — the
        // correction was refused — and a second wording is not pasted under the first.
        let remainder = undeliveredRemainder(of: text)

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
            if let remainder, !remainder.isEmpty {
                showDirectRecordingPanel(withText: remainder)
            }
            return
        }

        guard !text.isEmpty else {
            dlog("App", "handleTranscriptionResult: empty text")
            hideOverlay()
            // Unless the recording already delivered: a stream that committed words and
            // then fell back to a batch upload which came back empty leaves the dictation
            // sitting in the user's document, and telling them nothing was transcribed
            // while they are looking at it is worse than saying nothing.
            guard inlineLedger.deliveredText.isEmpty else {
                dlog("App", "handleTranscriptionResult: empty final text, but the dictation was already delivered")
                return
            }
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
            // Everything was already pasted as it was committed — which is the point of
            // the exercise, not a failure of it.
            guard let remainder, !remainder.isEmpty else {
                dlog("App", "handleTranscriptionResult: nothing left to paste")
                return
            }
            deliver(remainder)
            return
        }

        // A draft already in the document covers every segment of the recording, and the
        // rewrite replaces all of it — so it has to be a rewrite of all of it. `finalText`
        // holds only the last segment after a device restart.
        let aiInput = inlineLedger.isEmpty ? text : speechEngine.spanLayer.text

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
            deliverAIResult(aiInput, recordID: speechEngine.lastRecordID)
            return
        }

        // Keep the overlay up (now in its loading state) while the LLM rewrites the text.
        isRefining = true
        let recordID = speechEngine.lastRecordID
        let context = focusContext
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var output = aiInput
            var sendIntent: TextRefinementService.SendIntent?
            do {
                let result = try await TextRefinementService.refine(aiInput, context: context)
                if Task.isCancelled { return }
                output = result.text
                sendIntent = result.sendIntent
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
                self.deliverAIResult(output, recordID: recordID)
            }
        }
    }

    /// Where an AI dictation's final text goes.
    ///
    /// With nothing delivered early, the ordinary paste. With a draft already in the
    /// document (`aiDraftWhileSpeaking`), the result replaces it in one write — or, when
    /// the result only adds to the draft (a failed rewrite falls back to the raw
    /// transcript, which usually does), the rest is pasted after it. A refused
    /// replacement pastes the result anyway: that is the user's call, getting the
    /// rewrite in matters more to them than the draft staying out of the way, so the
    /// document may then hold both.
    private func deliverAIResult(_ output: String, recordID: UUID?) {
        guard !inlineLedger.isEmpty else {
            deliver(output)
            return
        }

        let decision = FinalizePass.decide(
            ledger: inlineLedger, authoritative: output, tier: deliveryTier,
            hasFrozenSpans: speechEngine.spanLayer.spans.contains { $0.state == .frozen })
        dlog("Span", "AI draft: \(decision)")

        switch decision {
        case .nothingDelivered:
            deliver(output)
        case .extend:
            if let rest = inlineLedger.remainder(of: output), !rest.isEmpty {
                deliver(rest)
            }
        case .replace, .leave:
            let applied = decision == .replace && correctDeliveredText(to: output)
            if let recordID {
                TranscriptionHistory.shared.recordCorrection(id: recordID, applied: applied)
            }
            guard !applied else { return }
            dlog("Span", "AI draft could not be replaced — pasting the AI result as well")
            deliver(output)
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
            self?.endInlineDelivery()
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
