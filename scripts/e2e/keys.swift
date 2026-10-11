// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

// scripts/e2e.sh's keyboard: posts key events through the HID event tap, as a keyboard
// would, so Carbon's global hotkeys see a real press and a real release. Not part of
// the app; e2e.sh compiles it with swiftc.
//
//   keys check                       is this process allowed to post events? (asks once)
//   keys down:ctrl+shift+q sleep:3.5 up:ctrl+shift+q tap:escape tap:cmd+a
//
// `down` presses the modifiers, then the key; `up` lets the key go, then the modifiers —
// the order a hand uses, and the one Carbon reports a hotkey's release from. `tap` is a
// down and an up 60 ms apart.

import ApplicationServices
import Foundation

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "right": 124, "left": 123, "down": 125, "up": 126,
]
let modifiers: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
    "ctrl": (59, .maskControl), "shift": (56, .maskShift),
    "alt": (58, .maskAlternate), "cmd": (55, .maskCommand),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let source = CGEventSource(stateID: .hidSystemState)

func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
        fail("could not create a key event")
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(8_000)
}

func parse(_ combo: String) -> (mods: [String], key: CGKeyCode) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let last = parts.last, let key = keyCodes[last] else { fail("unknown key in \(combo)") }
    let mods = Array(parts.dropLast())
    for mod in mods where modifiers[mod] == nil { fail("unknown modifier \(mod) in \(combo)") }
    return (mods, key)
}

func press(_ combo: String) {
    let (mods, key) = parse(combo)
    var flags: CGEventFlags = []
    for mod in mods {
        flags.insert(modifiers[mod]!.flag)
        // A modifier's own key event is a flags change; a key-down event of its code
        // with the flag set is how the HID tap posts one.
        post(modifiers[mod]!.code, down: true, flags: flags)
    }
    post(key, down: true, flags: flags)
}

func release(_ combo: String) {
    let (mods, key) = parse(combo)
    var flags = mods.reduce(into: CGEventFlags()) { $0.insert(modifiers[$1]!.flag) }
    post(key, down: false, flags: flags)
    for mod in mods.reversed() {
        flags.remove(modifiers[mod]!.flag)
        post(modifiers[mod]!.code, down: false, flags: flags)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["check"] {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) { print("trusted"); exit(0) }
    fail("not trusted")
}
guard !arguments.isEmpty else { fail("usage: keys check | keys down:COMBO up:COMBO tap:COMBO sleep:SECONDS …") }
guard AXIsProcessTrusted() else {
    fail("This process may not post key events: allow the app running it in System Settings › Privacy & Security › Accessibility.")
}
for step in arguments {
    let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("bad step \(step)") }
    switch parts[0] {
    case "down": press(parts[1])
    case "up": release(parts[1])
    case "tap": press(parts[1]); usleep(60_000); release(parts[1])
    case "sleep":
        guard let seconds = Double(parts[1]) else { fail("bad sleep \(parts[1])") }
        usleep(useconds_t(seconds * 1_000_000))
    default: fail("unknown step \(step)")
    }
}
