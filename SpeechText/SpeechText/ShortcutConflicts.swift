// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon.HIToolbox

/// A key combination as Carbon's hotkey APIs see it: a virtual key code and the four
/// modifiers a global shortcut can carry. Anything else in the mask (Caps Lock, the
/// fn key) is dropped, so two routes to the same combination compare equal.
struct KeyShortcut: Hashable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & Self.modifierMask
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, carbonModifiers: Self.carbonModifiers(modifiers))
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// The app's three global shortcuts, with where each is stored and what it is until
/// the user changes it.
enum ShortcutAction: CaseIterable, Hashable {
    case inline
    case ai
    case recordWindow

    var title: String {
        switch self {
        case .inline: return "Inline Recording"
        case .ai: return "AI Recording"
        case .recordWindow: return "Record Window"
        }
    }

    var keyCodeKey: String {
        switch self {
        case .inline: return SettingsKeys.hotkeyKeyCode
        case .ai: return SettingsKeys.aiHotkeyKeyCode
        case .recordWindow: return SettingsKeys.recordWindowHotkeyKeyCode
        }
    }

    var modifierFlagsKey: String {
        switch self {
        case .inline: return SettingsKeys.hotkeyModifierFlags
        case .ai: return SettingsKeys.aiHotkeyModifierFlags
        case .recordWindow: return SettingsKeys.recordWindowHotkeyModifierFlags
        }
    }

    var defaultKeyCode: UInt32 {
        switch self {
        case .inline: return 12        // Q
        case .ai: return 0             // A
        case .recordWindow: return 13  // W
        }
    }

    static let defaultModifiers: NSEvent.ModifierFlags = [.control, .shift]

    /// The stored combination, or the built-in one when none has been saved. Tests
    /// pass their own suite rather than the user's defaults.
    func stored(in defaults: UserDefaults) -> (keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return (defaultKeyCode, Self.defaultModifiers)
        }
        return (UInt32(defaults.integer(forKey: keyCodeKey)),
                NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifierFlagsKey))))
    }
}

/// Who else already answers a combination.
enum ShortcutConflict: Equatable {
    /// Another of the app's own shortcuts. Carbon hands a combination to one
    /// registration only, so the second would never fire.
    case action(ShortcutAction)
    /// An enabled macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts).
    /// The system takes those before any app sees them.
    case system

    /// What `candidate` would collide with if it became `action`'s shortcut. Only
    /// what can be known is checked: our own shortcuts and the system's. A global
    /// shortcut another app took through an event tap cannot be listed by anyone.
    static func find(_ candidate: KeyShortcut,
                     for action: ShortcutAction,
                     assigned: [ShortcutAction: KeyShortcut],
                     system: Set<KeyShortcut>) -> ShortcutConflict? {
        for other in ShortcutAction.allCases where other != action {
            if assigned[other] == candidate { return .action(other) }
        }
        return system.contains(candidate) ? .system : nil
    }
}
