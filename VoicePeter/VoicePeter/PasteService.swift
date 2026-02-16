import Cocoa
import ApplicationServices

struct PasteService {
    /// Pastes text at the current cursor position, preserving the user's clipboard.
    /// Saves clipboard contents, pastes via ⌘V, then restores the original clipboard.
    static func pasteAtCursor(_ text: String) {
        print("[PasteService] === pasteAtCursor called ===")
        print("[PasteService] Text (\(text.count) chars): \(text.prefix(80))...")
        print("[PasteService] AXIsProcessTrusted: \(AXIsProcessTrusted())")

        let frontApp = NSWorkspace.shared.frontmostApplication
        print("[PasteService] Frontmost app: \(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil"))")

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            restoreClipboard(pasteboard, items: savedItems)
            print("[PasteService] Clipboard restored")
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
        print("[PasteService] Activating: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")

        // Try NSRunningApplication.activate first
        let result = app.activate()
        print("[PasteService] NSRunningApplication.activate: \(result)")

        if !result, let bundleID = app.bundleIdentifier {
            // Fallback to AppleScript only if direct activation failed
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)" to activate
            """)
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            if let err {
                print("[PasteService] AppleScript activate failed: \(err)")
            } else {
                print("[PasteService] AppleScript activate succeeded")
            }
        }
    }

    /// Check whether the given app has a focused element that accepts text input.
    /// Uses Accessibility APIs to inspect the focused UI element.
    static func hasFocusedTextInput(in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return true } // Can't check — assume yes

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        // Primary check: is the value attribute settable? (accepts text input)
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            axElement,
            kAXValueAttribute as CFString,
            &isSettable
        )

        if settableResult == .success && isSettable.boolValue {
            return true
        }

        // Fallback: check role for known text input types
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)

        if let roleString = role as? String {
            return roleString == (kAXTextFieldRole as String) ||
                   roleString == (kAXTextAreaRole as String) ||
                   roleString == (kAXComboBoxRole as String)
        }

        return false
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
        print("[PasteService] CGEvent ⌘V posted")
    }
}
