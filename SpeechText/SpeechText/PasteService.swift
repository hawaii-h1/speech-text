// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import ApplicationServices

/// `InlineDelivery`'s window onto a real app: the app the recording started in, and the
/// field that had focus then, reached through `PasteService`.
final class AccessibilityDeliveryTarget: InlineDeliveryTarget {
    let app: NSRunningApplication?
    /// The field this recording delivers into, taken when the tier is decided. The stop's
    /// correction runs only while this is still the focused element of the app in front:
    /// the tier was decided for this field, not for whatever has focus by the stop.
    private var element: AXUIElement?

    init(app: NSRunningApplication?) {
        self.app = app
    }

    var acceptsDeliveryNow: Bool {
        guard PasteService.isAccessibilityGranted, let app else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    func paste(_ text: String, completion: @escaping (PasteLanding?) -> Void) {
        PasteService.pasteAtCursor(text, completion: completion)
    }

    func captureFocusedField() {
        element = PasteService.focusedElement(of: app)
    }

    func releaseFocusedField() {
        element = nil
    }

    var isStillFocused: Bool {
        guard let app, let element else { return false }
        return PasteService.isStillFocused(element, in: app)
    }

    func replaceDelivered(ledger: inout InsertionLedger, with text: String) -> Bool {
        guard let app else { return false }
        return PasteService.replaceLastInsertions(ledger: &ledger, with: text, in: app)
    }
}

struct PasteService {
    /// Pastes text at the current cursor position, preserving the user's clipboard.
    /// Saves clipboard contents, pastes via ⌘V, then restores the original clipboard.
    ///
    /// `completion` receives where the text landed, when that can be established: the
    /// caret is read before the ⌘V and polled after it, and the range between is read
    /// back out of `kAXValueAttribute`. It is nil whenever anything in that chain
    /// refuses — no permission, no focused element, a caret that never moved — and a nil
    /// landing means only that this paste cannot be corrected later, never that it failed.
    static func pasteAtCursor(_ text: String, completion: ((PasteLanding?) -> Void)? = nil) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        dlog("Paste", "pasteAtCursor: \(text.count) chars \"\(text.prefix(80))\", trusted=\(AXIsProcessTrusted()), front=\(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil"))")

        let element = completion == nil ? nil : focusedTextElement(of: frontApp)
        let before = element.flatMap { selectedRange(of: $0) }

        let pasteboard = NSPasteboard.general
        stageClipboard(pasteboard, text: text)

        // Use CGEvent as primary method — it only requires Accessibility permission,
        // unlike AppleScript which also needs Automation permission for System Events
        // and com.apple.security.automation.apple-events entitlement with hardened runtime.
        simulatePasteCGEvent()

        scheduleClipboardRestore(pasteboard)

        guard let completion else { return }
        guard let element, let before else {
            completion(nil)
            return
        }
        awaitLanding(in: element, startedAt: before, completion: completion)
    }

    // MARK: - Where the paste landed

    /// Polls the caret until it moves, then reads the text between where it was and
    /// where it is. The ⌘V is handled in another process on its own schedule, so there
    /// is nothing to wait on but the caret itself.
    ///
    /// The poll deliberately waits for the caret to *change* rather than to advance by
    /// the length of what was sent: an app with smart quotes or line-ending
    /// normalisation on inserts a different number of characters than we handed it, and
    /// a length test would wait out its whole timeout on every such app.
    private static func awaitLanding(in element: AXUIElement,
                                     startedAt before: NSRange,
                                     attempt: Int = 0,
                                     completion: @escaping (PasteLanding?) -> Void) {
        // ~500ms in 20ms steps. Past that the paste either did not happen or went
        // somewhere we cannot see, and either way there is nothing to record.
        let maxAttempts = 25

        guard let now = selectedRange(of: element), now != before else {
            guard attempt < maxAttempts else {
                dlog("Paste", "landing: caret never moved, nothing recorded")
                completion(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                awaitLanding(in: element, startedAt: before, attempt: attempt + 1, completion: completion)
            }
            return
        }

        // The paste replaced the selection, so it starts where the selection did and
        // ends at the caret.
        let start = before.location
        let length = now.location - start
        guard length > 0, let value = stringValue(of: element) else {
            dlog("Paste", "landing: caret moved to \(now.location) from \(start) — no usable range")
            completion(nil)
            return
        }

        let document = value as NSString
        guard NSMaxRange(NSRange(location: start, length: length)) <= document.length else {
            dlog("Paste", "landing: range \(start)+\(length) is outside a \(document.length)-char value")
            completion(nil)
            return
        }

        let range = NSRange(location: start, length: length)
        let landed = document.substring(with: range)
        dlog("Paste", "landing: \(range.location)+\(range.length) \"\(landed.prefix(40))\"")
        completion(PasteLanding(range: range, text: landed))
    }

    // MARK: - The finalizing pass

    /// The focused text element of `app` — kept at the start of a recording so the stop
    /// can tell whether it is still writing into the same field.
    static func focusedElement(of app: NSRunningApplication?) -> AXUIElement? {
        focusedTextElement(of: app)
    }

    /// Whether `app` is still in front with `element` still focused — the tier decided at
    /// the start still describes where a write would go. Anything else (the user switched
    /// apps, clicked into another field, closed the document) and the pass does not run.
    static func isStillFocused(_ element: AXUIElement, in app: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let now = focusedTextElement(of: app) else { return false }
        return CFEqual(now, element)
    }

    /// Replaces everything `ledger` recorded in `app`'s focused field with `text`, in one
    /// write, and records it. Every step checks before it changes anything; any refusal
    /// returns false with the document untouched. Never simulates a backspace.
    ///
    /// 1. The focused element belongs to `app` and answers `kAXValueAttribute`.
    /// 2. `FinalizePass.plan` finds all of the recorded text, untouched, as one range.
    /// 3. That range is selected, and reading the selection back confirms it.
    /// 4. The selection is written through `kAXSelectedTextAttribute`; an element that
    ///    will not take that write gets a ⌘V over the confirmed selection instead, with
    ///    the clipboard preserved as for every paste.
    /// 5. The caret goes to the end of the new text.
    static func replaceLastInsertions(ledger: inout InsertionLedger, with text: String,
                                      in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted(), let element = focusedTextElement(of: app) else {
            dlog("Span", "correction refused: no focused element")
            return false
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier,
              let document = stringValue(of: element) else {
            dlog("Span", "correction refused: the focused element is not \(app.localizedName ?? "the target")'s, or has no value")
            return false
        }

        guard let plan = FinalizePass.plan(ledger: ledger, document: document, replacement: text) else {
            dlog("Span", "correction refused: the delivered text is not all there, untouched, in one place")
            return false
        }

        guard setSelectedRange(plan.range, of: element), selectedRange(of: element) == plan.range else {
            dlog("Span", "correction refused: selecting \(plan.range.location)+\(plan.range.length) did not read back")
            return false
        }

        var settable = DarwinBoolean(false)
        let canWrite = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
        let wroteThroughAX = canWrite
            && AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, plan.text as CFString) == .success
        if wroteThroughAX {
            dlog("Span", "correction: replaced \(plan.range.location)+\(plan.range.length) through AX")
        } else {
            // The selection is confirmed, so ⌘V replaces exactly it.
            dlog("Span", "correction: selected-text write refused — pasting over the confirmed selection")
            pasteAtCursor(plan.text)
        }

        let length = (plan.text as NSString).length
        // Only after an AX write. The ⌘V is handled by the app after this returns, so a
        // caret move here would land first, collapse the confirmed selection, and the
        // paste would put the corrected text *after* the old text instead of over it.
        // The paste leaves the caret at the end of what it inserted on its own.
        if wroteThroughAX {
            _ = setSelectedRange(NSRange(location: plan.range.location + length, length: 0), of: element)
        }

        // What the app now holds there, when it can be read already. The ⌘V fallback has
        // not landed yet when this runs, so its record is optimistic: the text as sent,
        // at the confirmed selection.
        var landed = plan.text
        if wroteThroughAX, let value = stringValue(of: element) as NSString?,
           plan.range.location + length <= value.length {
            let read = value.substring(with: NSRange(location: plan.range.location, length: length))
            if read != plan.text { dlog("Span", "correction: the app holds \"\(read.prefix(40))\", not what was written") }
            landed = read
        }
        ledger.collapse(into: plan, landed: landed)
        dlog("Span", "correction applied: \"\(plan.text.prefix(60))\"")
        return true
    }

    private static func setSelectedRange(_ range: NSRange, of element: AXUIElement) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    // MARK: - Tier probe

    /// What the Accessibility API will let us do to this app's focused text element.
    ///
    /// The read-back is the whole point: Chromium answers `.success` to a selected-range
    /// write and then reports a different range, so only writing the range the element
    /// already has — a no-op for the user — and comparing what comes back separates an
    /// app we can correct from one we would be scribbling into blind.
    static func probeFocusedText(in app: NSRunningApplication?) -> AXTextProbe {
        guard AXIsProcessTrusted(), let element = focusedTextElement(of: app) else {
            return .unavailable
        }

        var probe = AXTextProbe()
        probe.valueReadable = stringValue(of: element) != nil

        guard let range = selectedRange(of: element) else { return probe }
        probe.rangeReadable = true

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return probe
        }

        // Setting the selection to what it already is changes nothing the user can see.
        var value = range
        guard let axValue = AXValueCreate(.cfRange, &value) else { return probe }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success else {
            return probe
        }
        probe.rangeReadsBack = selectedRange(of: element) == range
        return probe
    }

    /// Where the text is going: the app, its focused window's title and the focused
    /// field's label, or nil when there is nothing that may be sent (see `FocusContext.capture`).
    ///
    /// Only the LLM pass after the stop reads this, so the caller takes it *after* the
    /// microphone has been asked to start: these are round trips to another process, and
    /// against a slow app they would otherwise be time the user loses a first syllable to.
    static func readFocusContext(in app: NSRunningApplication?) -> FocusContext? {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        var windowTitle: String?
        var fieldLabels: [String?] = []
        var isSecureField = false
        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(target.processIdentifier)
            if let window = elementValue(of: appElement, kAXFocusedWindowAttribute) {
                windowTitle = attributeString(of: window, kAXTitleAttribute)
            }
            if let element = focusedTextElement(of: target) {
                isSecureField = attributeString(of: element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
                fieldLabels = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
                    .map { attributeString(of: element, $0) }
            }
        }
        return FocusContext.capture(appName: target.localizedName,
                                    bundleID: target.bundleIdentifier,
                                    windowTitle: windowTitle,
                                    fieldLabels: fieldLabels,
                                    isSecureField: isSecureField)
    }

    /// The focused element of `app`, or of whatever is frontmost when `app` is nil.
    private static func focusedTextElement(of app: NSRunningApplication?) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        guard let pid = (app ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func attributeString(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func elementValue(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        attributeString(of: element, kAXValueAttribute)
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    // MARK: - Clipboard

    /// The user's clipboard, taken before the first paste of a burst, and the restore
    /// waiting to put it back.
    ///
    /// A recording that inserts each committed span pastes several times, and the
    /// naive version — save, paste, restore in 1 s, per paste — corrupts the clipboard
    /// rather than preserving it: the second paste's "save" reads back the *first
    /// paste's text*, and a second later the user's clipboard holds a fragment of their
    /// own dictation. So the snapshot is taken once per burst and the pending restore is
    /// cancelled and rescheduled, never re-taken.
    private static var savedClipboard: [NSPasteboardItem]?
    private static var pendingRestore: DispatchWorkItem?

    /// Puts `text` on the pasteboard, keeping the user's own contents safe.
    private static func stageClipboard(_ pasteboard: NSPasteboard, text: String) {
        if pendingRestore == nil {
            savedClipboard = saveClipboard(pasteboard)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Restores the user's clipboard after a generous delay to ensure the target app has
    /// fully processed the paste command and read from the clipboard.
    ///
    /// This is a blind wait on purpose: the ⌘V lands in *another* process, and there is
    /// no signal from it telling us when it has read the pasteboard. No completion can
    /// replace this delay, so leave it at 1.0s. A paste that arrives before the previous
    /// restore fires pushes it out rather than stacking a second one behind it.
    private static func scheduleClipboardRestore(_ pasteboard: NSPasteboard) {
        pendingRestore?.cancel()
        let restore = DispatchWorkItem {
            let items = savedClipboard ?? []
            restoreClipboard(pasteboard, items: items)
            savedClipboard = nil
            pendingRestore = nil
            dlog("Paste", "Clipboard restored")
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: restore)
    }

    /// Save current clipboard contents so they can be restored later.
    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        var saved: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }
        return saved
    }

    /// Restore previously saved clipboard contents.
    private static func restoreClipboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// Activate a specific app (used to switch back to user's app before pasting)
    static func activateApp(_ app: NSRunningApplication) {
        dlog("Paste", "Activating: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")

        // Try NSRunningApplication.activate first
        let result = app.activate()
        dlog("Paste", "NSRunningApplication.activate: \(result)")

        if !result, let bundleID = app.bundleIdentifier {
            // Fallback to AppleScript only if direct activation failed
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)" to activate
            """)
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            if let err {
                dlog("Paste", "AppleScript activate failed: \(err)")
            } else {
                dlog("Paste", "AppleScript activate succeeded")
            }
        }
    }

    /// Check whether the given app likely accepts pasted text.
    /// Uses a denylist approach: returns true unless the focused element is a known
    /// non-text role (button, table, list, etc.). Unknown roles (including Electron/Chromium
    /// custom elements) default to true so paste is attempted.
    /// Returns false only when there is no focused element or it's definitely not a text input.
    static func canLikelyPasteText(in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return true } // Can't check — assume yes

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            // Can't determine focused element — common in Electron/web apps (Slack, Discord,
            // VS Code, etc.) whose text inputs don't appear in the native AX tree.
            // Default to attempting paste rather than falling back to Record Window.
            return true
        }

        let axElement = element as! AXUIElement

        // Quick positive: if the value attribute is settable, it's definitely a text input
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            axElement,
            kAXValueAttribute as CFString,
            &isSettable
        )
        if settableResult == .success && isSettable.boolValue {
            return true
        }

        // Denylist: roles that definitely don't accept pasted text.
        // Everything NOT in this list (including unknown Electron roles) defaults to "try paste".
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)

        if let roleString = role as? String {
            let nonTextRoles: Set<String> = [
                kAXButtonRole as String,
                kAXCheckBoxRole as String,
                kAXRadioButtonRole as String,
                kAXMenuItemRole as String,
                kAXMenuBarRole as String,
                kAXMenuRole as String,
                kAXToolbarRole as String,
                kAXScrollBarRole as String,
                kAXImageRole as String,
                kAXStaticTextRole as String,
                kAXListRole as String,
                kAXOutlineRole as String,
                kAXTableRole as String,
                kAXBrowserRole as String,
                kAXTabGroupRole as String,
                kAXScrollAreaRole as String,
                kAXSplitGroupRole as String,
                kAXSplitterRole as String,
                kAXWindowRole as String,
            ]
            if nonTextRoles.contains(roleString) {
                return false
            }
        }

        // Unknown or unrecognized role — default to trying paste
        return true
    }

    /// Check if accessibility is granted
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant accessibility permission
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private static func simulatePasteCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
        dlog("Paste", "CGEvent ⌘V posted")
    }
}
