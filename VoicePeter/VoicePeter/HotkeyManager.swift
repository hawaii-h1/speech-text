import Cocoa
import Carbon.HIToolbox

@Observable
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var notificationObserver: Any?
    var onToggle: (() -> Void)?

    private var keyCode: UInt32 = 49
    private var cocoaModifiers: NSEvent.ModifierFlags = .option

    func start() {
        loadHotkey()
        registerHotkey()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHotkey()
        }
    }

    func stop() {
        unregisterHotkey()
    }

    private func loadHotkey() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKeys.hotkeyKeyCode) != nil {
            keyCode = UInt32(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode))
            cocoaModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.hotkeyModifierFlags)))
        }
    }

    private func reloadHotkey() {
        unregisterHotkey()
        loadHotkey()
        registerHotkey()
    }

    private func registerHotkey() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, _: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    mgr.onToggle?()
                }
                return noErr
            },
            1,
            &eventType,
            refcon,
            &eventHandlerRef
        )

        let carbonMods = Self.cocoaToCarbonModifiers(cocoaModifiers)
        let hotKeyID = EventHotKeyID(signature: OSType(0x56504852), id: 1)
        RegisterEventHotKey(keyCode, carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static func cocoaToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    deinit {
        stop()
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
