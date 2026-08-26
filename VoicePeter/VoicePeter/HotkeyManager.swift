import Cocoa
import Carbon.HIToolbox

@Observable
final class HotkeyManager {
    private var inlineHotKeyRef: EventHotKeyRef?
    private var recordWindowHotKeyRef: EventHotKeyRef?
    private var aiHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var notificationObserver: Any?

    var onInlineToggle: (() -> Void)?
    var onRecordWindowToggle: (() -> Void)?
    var onAIToggle: (() -> Void)?

    // Inline recording hotkey
    private var inlineKeyCode: UInt32 = 12  // Q
    private var inlineModifiers: NSEvent.ModifierFlags = [.control, .shift]

    // Record window hotkey
    private var recordWindowKeyCode: UInt32 = 13  // W
    private var recordWindowModifiers: NSEvent.ModifierFlags = [.control, .shift]

    // AI recording hotkey (transcription is post-processed by an LLM)
    private var aiKeyCode: UInt32 = 0  // A
    private var aiModifiers: NSEvent.ModifierFlags = [.control, .shift]

    private static let signature: OSType = 0x56504852
    private static let inlineID: UInt32 = 1
    private static let recordWindowID: UInt32 = 2
    private static let aiID: UInt32 = 3

    func start() {
        loadHotkeys()
        registerHotkeys()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHotkeys()
        }
    }

    func stop() {
        unregisterHotkeys()
    }

    private func loadHotkeys() {
        let defaults = UserDefaults.standard

        // Inline
        if defaults.object(forKey: SettingsKeys.hotkeyKeyCode) != nil {
            inlineKeyCode = UInt32(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode))
            inlineModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.hotkeyModifierFlags)))
        }

        // Record window
        if defaults.object(forKey: SettingsKeys.recordWindowHotkeyKeyCode) != nil {
            recordWindowKeyCode = UInt32(defaults.integer(forKey: SettingsKeys.recordWindowHotkeyKeyCode))
            recordWindowModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.recordWindowHotkeyModifierFlags)))
        }

        // AI recording
        if defaults.object(forKey: SettingsKeys.aiHotkeyKeyCode) != nil {
            aiKeyCode = UInt32(defaults.integer(forKey: SettingsKeys.aiHotkeyKeyCode))
            aiModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.aiHotkeyModifierFlags)))
        }
    }

    private func reloadHotkeys() {
        unregisterHotkeys()
        loadHotkeys()
        registerHotkeys()
    }

    private func registerHotkeys() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Install single event handler for all hotkeys
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }

                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1: mgr.onInlineToggle?()
                    case 2: mgr.onRecordWindowToggle?()
                    case 3: mgr.onAIToggle?()
                    default: break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            refcon,
            &eventHandlerRef
        )

        // Register inline hotkey (id: 1)
        let inlineCarbonMods = Self.cocoaToCarbonModifiers(inlineModifiers)
        let inlineHotKeyID = EventHotKeyID(signature: Self.signature, id: Self.inlineID)
        RegisterEventHotKey(inlineKeyCode, inlineCarbonMods, inlineHotKeyID,
                            GetApplicationEventTarget(), 0, &inlineHotKeyRef)

        // Register record window hotkey (id: 2)
        let rwCarbonMods = Self.cocoaToCarbonModifiers(recordWindowModifiers)
        let rwHotKeyID = EventHotKeyID(signature: Self.signature, id: Self.recordWindowID)
        RegisterEventHotKey(recordWindowKeyCode, rwCarbonMods, rwHotKeyID,
                            GetApplicationEventTarget(), 0, &recordWindowHotKeyRef)

        // Register AI recording hotkey (id: 3)
        let aiCarbonMods = Self.cocoaToCarbonModifiers(aiModifiers)
        let aiHotKeyID = EventHotKeyID(signature: Self.signature, id: Self.aiID)
        RegisterEventHotKey(aiKeyCode, aiCarbonMods, aiHotKeyID,
                            GetApplicationEventTarget(), 0, &aiHotKeyRef)
    }

    private func unregisterHotkeys() {
        if let ref = inlineHotKeyRef {
            UnregisterEventHotKey(ref)
            inlineHotKeyRef = nil
        }
        if let ref = recordWindowHotKeyRef {
            UnregisterEventHotKey(ref)
            recordWindowHotKeyRef = nil
        }
        if let ref = aiHotKeyRef {
            UnregisterEventHotKey(ref)
            aiHotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
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
