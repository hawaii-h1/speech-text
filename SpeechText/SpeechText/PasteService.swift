import Cocoa
import ApplicationServices

struct PasteService {
    /// Pastes text at the current cursor position, preserving the user's clipboard.
    /// Saves clipboard contents, pastes via ⌘V, then restores the original clipboard.
    static func pasteAtCursor(_ text: String) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        dlog("Paste", "pasteAtCursor: \(text.count) chars \"\(text.prefix(80))\", trusted=\(AXIsProcessTrusted()), front=\(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil"))")

        let pasteboard = NSPasteboard.general
        let savedItems = saveClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Use CGEvent as primary method — it only requires Accessibility permission,
        // unlike AppleScript which also needs Automation permission for System Events
        // and com.apple.security.automation.apple-events entitlement with hardened runtime.
        simulatePasteCGEvent()

        // Restore the original clipboard after a generous delay to ensure the target app
        // has fully processed the paste command and read from the clipboard.
        // This is a blind wait on purpose: the ⌘V lands in *another* process, and there
        // is no signal from it telling us when it has read the pasteboard. No completion
        // can replace this delay, so leave it at 1.0s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            restoreClipboard(pasteboard, items: savedItems)
            dlog("Paste", "Clipboard restored")
        }
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
