import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    let label: String
    let keyCodeKey: String
    let modifierFlagsKey: String
    let defaultKeyCode: Int
    let defaultModifierFlags: Int

    @State private var keyCode: Int
    @State private var modifierFlags: Int
    @State private var isRecording = false
    @State private var localMonitor: Any?

    init(
        label: String = "Shortcut",
        keyCodeKey: String = SettingsKeys.hotkeyKeyCode,
        modifierFlagsKey: String = SettingsKeys.hotkeyModifierFlags,
        defaultKeyCode: Int = 0,  // A
        defaultModifierFlags: Int = Int(NSEvent.ModifierFlags([.control, .shift]).rawValue)
    ) {
        self.label = label
        self.keyCodeKey = keyCodeKey
        self.modifierFlagsKey = modifierFlagsKey
        self.defaultKeyCode = defaultKeyCode
        self.defaultModifierFlags = defaultModifierFlags

        let defaults = UserDefaults.standard
        let kc = defaults.object(forKey: keyCodeKey) != nil
            ? defaults.integer(forKey: keyCodeKey)
            : defaultKeyCode
        let mf = defaults.object(forKey: modifierFlagsKey) != nil
            ? defaults.integer(forKey: modifierFlagsKey)
            : defaultModifierFlags
        _keyCode = State(initialValue: kc)
        _modifierFlags = State(initialValue: mf)
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(action: toggleRecording) {
                if isRecording {
                    Text("Press shortcut...")
                        .foregroundStyle(.red)
                        .frame(minWidth: 140)
                } else {
                    Text(shortcutDisplayString(keyCode: UInt16(keyCode),
                                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))))
                        .frame(minWidth: 140)
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard !modifierKeyCodes.contains(event.keyCode) else { return event }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return event }

            self.keyCode = Int(event.keyCode)
            self.modifierFlags = Int(mods.rawValue)

            UserDefaults.standard.set(self.keyCode, forKey: keyCodeKey)
            UserDefaults.standard.set(self.modifierFlags, forKey: modifierFlagsKey)

            stopListening()
            NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)

            return nil
        }
    }

    private func stopListening() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let hotkeyDidChange = Notification.Name("hotkeyDidChange")
}

// MARK: - Display Helpers

func shortcutDisplayString(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String {
    var parts: [String] = []
    if modifierFlags.contains(.control) { parts.append("\u{2303}") }
    if modifierFlags.contains(.option) { parts.append("\u{2325}") }
    if modifierFlags.contains(.shift) { parts.append("\u{21E7}") }
    if modifierFlags.contains(.command) { parts.append("\u{2318}") }
    parts.append(keyCodeToString(keyCode))
    return parts.joined()
}

func keyCodeToString(_ keyCode: UInt16) -> String {
    switch keyCode {
    case 49: return "Space"
    case 36: return "Return"
    case 48: return "Tab"
    case 51: return "Delete"
    case 53: return "Escape"
    case 123: return "\u{2190}"
    case 124: return "\u{2192}"
    case 125: return "\u{2193}"
    case 126: return "\u{2191}"
    default:
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key\(keyCode)"
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        layoutData.withUnsafeBytes { ptr in
            let layoutPtr = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        if length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
        return "Key\(keyCode)"
    }
}
