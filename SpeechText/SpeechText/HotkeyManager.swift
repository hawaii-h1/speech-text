// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import Carbon.HIToolbox

/// Which of the app's shortcuts macOS refused to register, and why. Settings reads it to
/// say so under the shortcut, since a refused shortcut otherwise just never fires.
@Observable
final class HotkeyRegistrationStatus {
    static let shared = HotkeyRegistrationStatus()
    var failures: [ShortcutAction: OSStatus] = [:]
}

/// Which of the app's shortcuts are down right now. Carbon reports a hotkey's release
/// only when its *key* comes up, whatever the modifiers do, so this is the letter: a
/// hold recording goes on with ⌃⇧ let go and Q still down (#79). The keycaps in
/// Settings and setup and the hold tip read it; the modifiers they read off
/// `NSEvent.modifierFlags`.
@Observable
final class HeldShortcuts {
    static let shared = HeldShortcuts()
    private(set) var down: Set<ShortcutAction> = []

    func set(_ action: ShortcutAction, isDown: Bool) {
        if isDown { down.insert(action) } else { down.remove(action) }
    }

    /// Unregistered hotkeys report no releases; none may be left looking held.
    func clear() {
        if !down.isEmpty { down = [] }
    }
}

@Observable
final class HotkeyManager {
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var observers: [Any] = []
    /// Recorders currently listening. While any is, nothing is registered: a combination
    /// that is already one of ours would otherwise start a dictation instead of reaching
    /// the recorder, which then could not tell the user it is taken.
    private var recorderPauses = 0

    /// A dictation shortcut went down (`true`) or came back up (`false`). Releases are
    /// what hold-to-talk runs on; `AppState` decides whether one means anything.
    var onDictationKey: ((DictationHotkey, Bool) -> Void)?
    var onRecordWindowToggle: (() -> Void)?
    /// The Edit shortcut went down (`true`) or came back up (`false`). Both matter: a
    /// double press sends the selection with no instruction, and a hold is one.
    var onEditKey: ((Bool) -> Void)?
    /// Bare ⎋, which exists only while `setEscapeShortcut(active: true)`.
    var onEscape: (() -> Void)?
    private var escapeRef: EventHotKeyRef?
    private var escapeWanted = false
    private static let escapeHotKeyID: UInt32 = 5

    private var shortcuts: [ShortcutAction: KeyShortcut] = [:]

    private static let signature: OSType = 0x56504852

    private static func hotKeyID(_ action: ShortcutAction) -> UInt32 {
        switch action {
        case .inline: return 1
        case .recordWindow: return 2
        case .ai: return 3
        case .edit: return 4
        }
    }

    func start() {
        loadHotkeys()
        registerHotkeys()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .hotkeyDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.reloadHotkeys()
            },
            center.addObserver(forName: .hotkeyRecorderDidStart, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.recorderPauses += 1
                if self.recorderPauses == 1 { self.unregisterHotkeys() }
            },
            center.addObserver(forName: .hotkeyRecorderDidStop, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.recorderPauses > 0 else { return }
                self.recorderPauses -= 1
                if self.recorderPauses == 0 { self.reloadHotkeys() }
            },
        ]
    }

    func stop() {
        unregisterHotkeys()
    }

    private func loadHotkeys() {
        let defaults = UserDefaults.standard
        for action in ShortcutAction.allCases {
            let stored = action.stored(in: defaults)
            shortcuts[action] = KeyShortcut(keyCode: stored.keyCode, modifiers: stored.modifiers)
        }
    }

    private func reloadHotkeys() {
        unregisterHotkeys()
        loadHotkeys()
        // A recorder still listening re-registers when it stops; the new values are loaded.
        guard recorderPauses == 0 else { return }
        registerHotkeys()
    }

    private func registerHotkeys() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Install single event handler for all hotkeys, for presses and releases alike
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let handlerStatus = InstallEventHandler(
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
                let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)

                DispatchQueue.main.async {
                    if let action = ShortcutAction.allCases.first(where: { HotkeyManager.hotKeyID($0) == hotKeyID.id }) {
                        HeldShortcuts.shared.set(action, isDown: isDown)
                    }
                    switch hotKeyID.id {
                    case 1: mgr.onDictationKey?(.inline, isDown)
                    case 2: if isDown { mgr.onRecordWindowToggle?() }
                    case 3: mgr.onDictationKey?(.ai, isDown)
                    case 4: mgr.onEditKey?(isDown)
                    case HotkeyManager.escapeHotKeyID: if isDown { mgr.onEscape?() }
                    default: break
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            refcon,
            &eventHandlerRef
        )
        if handlerStatus != noErr {
            dlog("Hotkey", "InstallEventHandler failed (status \(handlerStatus)) — no shortcut will fire")
        }

        var failures: [ShortcutAction: OSStatus] = [:]
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: Self.hotKeyID(action)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs[action] = ref
            } else {
                // A combination another app reserved, or one of ours twice, comes back as
                // an error here and then simply never fires — indistinguishable from a
                // broken app unless it is said out loud.
                failures[action] = status
                dlog("Hotkey", "\(action.title) shortcut (key code \(shortcut.keyCode)) could not be registered: status \(status) — another app may already own it")
            }
        }
        HotkeyRegistrationStatus.shared.failures = failures
        applyEscapeShortcut()
    }

    /// Registers bare ⎋ as a global shortcut for as long as a dictation is on screen. A
    /// Carbon hotkey is exclusive: while it stands, ⎋ reaches no other app — no dialog
    /// dismissed, no vim mode left — which is why this is a setting, off by default, and
    /// why it is dropped the moment the overlay goes.
    func setEscapeShortcut(active: Bool) {
        escapeWanted = active
        applyEscapeShortcut()
    }

    private func applyEscapeShortcut() {
        // No handler means a recorder is listening, and ⎋ is how it gives up.
        let shouldExist = escapeWanted && eventHandlerRef != nil
        if shouldExist, escapeRef == nil {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Escape), 0,
                                             EventHotKeyID(signature: Self.signature, id: Self.escapeHotKeyID),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr { escapeRef = ref } else {
                dlog("Hotkey", "⎋ could not be registered: status \(status)")
            }
        } else if !shouldExist, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
    }

    private func unregisterHotkeys() {
        HeldShortcuts.shared.clear()
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs = [:]
        if let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    /// The enabled macOS shortcuts (System Settings › Keyboard › Keyboard Shortcuts).
    /// The system acts on these before any app sees the key.
    static func enabledSystemShortcuts() -> Set<KeyShortcut> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int else { return nil }
            return KeyShortcut(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers))
        })
    }

    deinit {
        stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
