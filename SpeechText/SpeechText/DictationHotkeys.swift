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
/// A press follows one table in every mode. Idle, it starts a dictation in its own mode.
/// During one, the shortcut of the mode it is in stops it and the other shortcut switches
/// it over — so a dictation begun as plain text can still be sent through the AI, and the
/// other way round. Once the audio is closed (transcribing, rewriting) either shortcut
/// cancels, as it always has: there is nothing left to switch.
///
/// Releases matter only with `holdToTalk`. The press that started the dictation *owns* it,
/// and letting go of that shortcut stops it — unless it was let go within `tapThreshold`,
/// which is a tap: the dictation stays on until the next press, exactly as with the setting
/// off. One shortcut therefore serves both habits, and a press too short to hold a word
/// does not end in "No speech detected". Only the owner's release counts, which is what
/// lets a held dictation switch modes: hold ⌃⇧Q, tap ⌃⇧A, keep talking, let go of Q.
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

    /// Shorter than this, a release is the end of a tap rather than of a hold. Long
    /// enough for a deliberate keypress, short enough that no one says a word in it.
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
        guard time - pressedAt >= Self.tapThreshold else { return .ignore }
        switch phase {
        case .starting: return .cancel
        case .recording: return .stop
        case .idle, .busy: return .ignore
        }
    }
}
