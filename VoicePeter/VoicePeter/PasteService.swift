import Cocoa
import ApplicationServices

struct PasteService {
    /// Pastes text at the current cursor position.
    /// Sets clipboard, then simulates ⌘V via multiple methods.
    static func pasteAtCursor(_ text: String) {
        print("[PasteService] === pasteAtCursor called ===")
        print("[PasteService] Text (\(text.count) chars): \(text.prefix(80))...")
        print("[PasteService] AXIsProcessTrusted: \(AXIsProcessTrusted())")

        let frontApp = NSWorkspace.shared.frontmostApplication
        print("[PasteService] Frontmost app: \(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil"))")

        // Set clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("[PasteService] Clipboard set")

        // Method 1: AppleScript keystroke ⌘V (most reliable across apps)
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        var scriptError: NSDictionary?
        script?.executeAndReturnError(&scriptError)

        if let scriptError {
            print("[PasteService] AppleScript failed: \(scriptError)")
            print("[PasteService] Falling back to CGEvent")
            // Method 2: CGEvent fallback
            simulatePasteCGEvent()
        } else {
            print("[PasteService] AppleScript ⌘V succeeded")
        }
    }

    /// Activate a specific app (used to switch back to user's app before pasting)
    static func activateApp(_ app: NSRunningApplication) {
        print("[PasteService] Activating: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")

        // Try NSRunningApplication.activate first
        let result = app.activate()
        print("[PasteService] NSRunningApplication.activate: \(result)")

        // Also try AppleScript as backup
        if let bundleID = app.bundleIdentifier {
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

    /// Check if accessibility is granted
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant accessibility permission
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
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
