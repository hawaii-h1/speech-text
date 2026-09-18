// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two shortcuts that start an inline dictation. The Record Window's shortcut is not
/// one of them: it opens a panel, and holding it means nothing.
enum DictationHotkey: Equatable {
    case inline
    case ai

    var isAI: Bool { self == .ai }
}

/// What one press or release of a dictation shortcut does.
enum DictationHotkeyAction: Equatable {
    case start(ai: Bool)
    /// The recording goes on in the other mode: what is said is the same dictation, only
    /// what happens to it at the stop changes.
    case switchTo(ai: Bool)
    case stop
    case cancel
    case ignore
}

/// Turns presses and releases of the two dictation shortcuts into actions.
///
/// A press follows one table, the held dictation below aside. Idle, it starts a dictation in its own mode.
/// During one, the shortcut of the mode it is in stops it and the other shortcut switches
/// it over — so a dictation begun as plain text can still be sent through the AI, and the
/// other way round. Once the audio is closed (transcribing, rewriting) either shortcut
/// cancels, as it always has: there is nothing left to switch.
///
/// Releases matter only with `holdToTalk`. The press that started the dictation *owns* it,
/// and letting go of that shortcut stops it. A release within `tapThreshold` is a tap, not
/// a hold, and cancels: nothing was said in it, and a tap that latched the recording on
/// left an overlay listening that the user had not asked for. Hands-free dictation is the
/// setting switched off.
///
/// While the owner is held, the other shortcut cannot stop the dictation — only the
/// owner's release does — so each of its presses flips the mode instead: hold ⌃⇧Q, tap
/// ⌃⇧A for AI, tap it again for plain text, let go of Q. The owner itself cannot be pressed
/// again while it is down; a press of it means its release never arrived, and it follows
/// the table, so a missed release costs one extra press rather than a stuck recording.
///
/// Pure logic, in both targets; `AppState` supplies the phase and performs the action.
struct DictationHotkeyGesture {
    enum Phase: Equatable {
        case idle
        /// The microphone is not open yet. Nothing has been recorded, so a stop here
        /// is a cancel.
        case starting(ai: Bool)
        case recording(ai: Bool)
        /// Transcribing or rewriting — the audio is closed.
        case busy
    }

    /// Shorter than this, a release is the end of a tap rather than of a hold, and cancels.
    /// Long enough for a deliberate keypress, short enough that no one says a word in it.
    static let tapThreshold: TimeInterval = 0.3

    var holdToTalk = false
    /// The shortcut whose press started the current dictation, while it is still down.
    private(set) var owner: DictationHotkey?
    private var pressedAt: TimeInterval = 0

    init(holdToTalk: Bool = false) {
        self.holdToTalk = holdToTalk
    }

    /// A press of `key`, the same table with or without hold-to-talk.
    static func action(forPressOf key: DictationHotkey, in phase: Phase) -> DictationHotkeyAction {
        switch phase {
        case .idle:
            return .start(ai: key.isAI)
        case .starting(let ai):
            return key.isAI == ai ? .cancel : .switchTo(ai: key.isAI)
        case .recording(let ai):
            return key.isAI == ai ? .stop : .switchTo(ai: key.isAI)
        case .busy:
            return .cancel
        }
    }

    mutating func press(_ key: DictationHotkey, in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        if let owner, key != owner {
            switch phase {
            case .starting(let ai), .recording(let ai):
                return .switchTo(ai: !ai)
            case .idle, .busy:
                break
            }
        }
        let action = Self.action(forPressOf: key, in: phase)
        switch action {
        case .start:
            owner = holdToTalk ? key : nil
            pressedAt = time
        case .stop, .cancel:
            // Its own release, still to come, must not act on whatever follows.
            owner = nil
        case .switchTo, .ignore:
            break
        }
        return action
    }

    /// A menu item: the press table with no key behind it, so no release will follow. A
    /// dictation it starts or ends has no owner.
    mutating func click(_ key: DictationHotkey, in phase: Phase) -> DictationHotkeyAction {
        let action = Self.action(forPressOf: key, in: phase)
        if case .switchTo = action {} else { owner = nil }
        return action
    }

    mutating func release(_ key: DictationHotkey, in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        guard key == owner else { return .ignore }
        owner = nil
        switch phase {
        case .starting: return .cancel
        case .recording: return time - pressedAt < Self.tapThreshold ? .cancel : .stop
        case .idle, .busy: return .ignore
        }
    }
}
