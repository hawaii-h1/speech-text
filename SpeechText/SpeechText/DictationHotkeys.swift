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
    case cancel(DictationCancelReason)
    /// A double tap with hold-to-talk on: the dictation carries on with no key held, and
    /// a later press stops it as the table says. Nothing to perform — it is the cancel
    /// that does not happen.
    case lock
    case ignore
}

/// Why a dictation was cancelled — what the notice says. No cancel is silent (#72): a
/// press that lands on the rewrite a moment after the stop throws the dictation away, and
/// with nothing on screen the user could not tell a cancel from a paste that failed.
enum DictationCancelReason: Equatable {
    /// A dictation shortcut pressed while the microphone was opening, or while the
    /// recording was being transcribed or rewritten.
    case shortcut
    /// Hold to talk: a lone tap, or a tap followed by the other shortcut.
    case tap
    /// Hold to talk: the shortcut let go before the microphone opened.
    case releasedEarly
    case escape
    /// The overlay's ✕.
    case closeButton
    /// The menu's recording item.
    case menu

    /// The notice's title and detail. `savedInHistory`: the dictation was already
    /// transcribed, and History holds it — so a cancel during the AI rewrite loses
    /// nothing the user cannot get back. The detail fits the notice's two lines.
    func notice(savedInHistory: Bool) -> (title: String, detail: String) {
        switch self {
        case .tap:
            return ("Dictation cancelled", "A quick tap cancels. Hold the shortcut while you speak, or double-tap to record hands-free.")
        case .releasedEarly:
            return ("Dictation cancelled", "The shortcut was let go before the microphone opened. Hold it until the overlay listens.")
        case .shortcut, .escape, .closeButton, .menu:
            return ("Dictation cancelled", savedInHistory
                    ? "Nothing was pasted. The dictation is saved in History."
                    : "Nothing was pasted.")
        }
    }
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
/// a hold: nothing was said in it, and a lone tap that latched the recording on left an
/// overlay listening that the user had not asked for — so it cancels. Not at once,
/// though: a second press of the same shortcut within `doubleTapWindow` of that release
/// makes it a double tap, which *is* asking, and locks the dictation on hands-free
/// (`.lock`). The first tap never waits — the microphone is already open — and is read
/// retroactively, as `EditHotkeyGesture` reads its own: `AppState` calls
/// `tapWindowExpired` when the window runs out, and that is the cancel. The other
/// shortcut pressed inside the window cancels too; it is not the second half of anything.
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
    /// After a tap's release, how long a second press still makes it a double tap. The
    /// Edit shortcut's window, so the two gestures feel the same.
    static let doubleTapWindow: TimeInterval = 0.35

    var holdToTalk = false
    /// The shortcut whose press started the current dictation, while it is still down.
    private(set) var owner: DictationHotkey?
    private var pressedAt: TimeInterval = 0
    /// The shortcut that was tapped, and when it came up, while the tap may still turn
    /// out to be the first half of a double tap.
    private var tapped: (key: DictationHotkey, releasedAt: TimeInterval)?

    /// A tap is waiting for its second half; `AppState` runs the timer.
    var awaitsSecondTap: Bool { tapped != nil }

    init(holdToTalk: Bool = false) {
        self.holdToTalk = holdToTalk
    }

    /// A press of `key`, the same table with or without hold-to-talk.
    static func action(forPressOf key: DictationHotkey, in phase: Phase) -> DictationHotkeyAction {
        switch phase {
        case .idle:
            return .start(ai: key.isAI)
        case .starting(let ai):
            return key.isAI == ai ? .cancel(.shortcut) : .switchTo(ai: key.isAI)
        case .recording(let ai):
            return key.isAI == ai ? .stop : .switchTo(ai: key.isAI)
        case .busy:
            return .cancel(.shortcut)
        }
    }

    mutating func press(_ key: DictationHotkey, in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        if let tap = tapped {
            tapped = nil
            switch phase {
            case .starting, .recording:
                let isSecondTap = key == tap.key && time - tap.releasedAt <= Self.doubleTapWindow
                return isSecondTap ? .lock : .cancel(.tap)
            case .idle, .busy:
                break
            }
        }
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
        case .switchTo, .lock, .ignore:
            break
        }
        return action
    }

    /// A menu item: the press table with no key behind it, so no release will follow. A
    /// dictation it starts or ends has no owner.
    mutating func click(_ key: DictationHotkey, in phase: Phase) -> DictationHotkeyAction {
        var action = Self.action(forPressOf: key, in: phase)
        if case .cancel = action { action = .cancel(.menu) }
        if case .switchTo = action {} else {
            owner = nil
            tapped = nil
        }
        return action
    }

    mutating func release(_ key: DictationHotkey, in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        guard key == owner else { return .ignore }
        owner = nil
        switch phase {
        case .starting, .recording:
            if time - pressedAt < Self.tapThreshold {
                tapped = (key, time)
                return .ignore
            }
            // A hold let go before the microphone opened has recorded nothing.
            if case .recording = phase { return .stop }
            return .cancel(.releasedEarly)
        case .idle, .busy:
            return .ignore
        }
    }

    /// `doubleTapWindow` after a tap's release, with no second press: the tap was all
    /// there was, and a lone tap cancels.
    mutating func tapWindowExpired(in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        guard let tap = tapped, time - tap.releasedAt >= Self.doubleTapWindow * 0.9 else { return .ignore }
        tapped = nil
        switch phase {
        case .starting, .recording: return .cancel(.tap)
        case .idle, .busy: return .ignore
        }
    }
}

// MARK: - Holding only the letter

/// How a key of a shortcut is drawn.
enum KeycapState: Equatable {
    case up
    case down
    /// A modifier of a held shortcut once its letter is down: with hold to talk the
    /// letter alone keeps the recording going (Carbon reports the hotkey's release only
    /// when the letter comes up), so ⌃ and ⇧ may be let go — and held on, they turn
    /// clicks into ⌃-clicks and ⌘Tab into ⌃⇧⌘Tab (#79).
    case notNeeded
}

/// The hold tip: teaching that a hold recording needs only its letter held (#79).
///
/// Shown beside the overlay for the first hold recordings, and gone once the user has
/// let go of the modifiers mid-recording `lessons` times; then, once, how to switch to
/// the other mode while holding. The count lives in `holdTipFollowedCount`. Pure logic,
/// in both targets; `AppState` shows the panel and keeps the count.
enum HoldTip {
    /// Hold recordings in which the tip was *followed* — the modifiers let go with the
    /// letter still down — before it stops appearing.
    static let lessons = 3

    enum Stage: Equatable {
        /// "Keep Q down — you can let go of ⌃⇧."
        case keepHolding
        /// "While holding, ⌃⇧A switches to AI." Shown once, after the lessons.
        case switchHint
        case none
    }

    /// What a hold recording shows. `canSwitch`: a dictation with another mode to switch
    /// to — not an edit, and not the AI shortcut while no AI is set up.
    static func stage(count: Int, canSwitch: Bool) -> Stage {
        if count < lessons { return .keepHolding }
        if count == lessons, canSwitch { return .switchHint }
        return .none
    }

    /// The count once a hold recording has ended.
    static func count(after count: Int, stage: Stage, followed: Bool) -> Int {
        switch stage {
        case .keepHolding: return followed ? count + 1 : count
        case .switchHint: return count + 1
        case .none: return count
        }
    }

    /// The caps of a shortcut: `modifiersDown` one per modifier cap, in order.
    static func keycaps(modifiersDown: [Bool], letterDown: Bool, holdToTalk: Bool)
        -> (modifiers: [KeycapState], letter: KeycapState) {
        let letter: KeycapState = letterDown ? .down : .up
        if holdToTalk, letterDown {
            return (modifiersDown.map { _ in .notNeeded }, letter)
        }
        return (modifiersDown.map { $0 ? .down : .up }, letter)
    }

    /// Whether the tip has been followed: every modifier up, the letter still down.
    static func isFollowed(modifiersDown: [Bool], letterDown: Bool) -> Bool {
        letterDown && !modifiersDown.isEmpty && !modifiersDown.contains(true)
    }

    /// The tip's words. `letter` and `modifiers` are the held shortcut's ("Q", "⌃⇧");
    /// `other` is the other dictation shortcut, for the switch hint. The panel gives the
    /// text about 210 pt beside the keycaps: the title fits one line, the detail two.
    static func text(stage: Stage, followed: Bool, isEdit: Bool, letter: String, modifiers: String,
                     other: String, otherIsAI: Bool) -> (title: String, detail: String) {
        switch stage {
        case .switchHint:
            return (otherIsAI ? "Switch to AI" : "Switch to plain text",
                    "While holding \(letter), press \(other). Press it again to switch back.")
        case .keepHolding, .none:
            if followed {
                return ("Just \(letter) — that's it",
                        isEdit ? "Let go of \(letter) to send the instruction." : "Let go of \(letter) when you're done.")
            }
            return ("You can let go of \(modifiers)", "\(letter) alone keeps recording, so clicks and ⌘Tab work as usual.")
        }
    }

    // The looping demo beside Settings › Hold to talk.

    static let demoPeriod: TimeInterval = 4.8

    enum DemoStep: Equatable {
        /// Nothing pressed.
        case rest
        /// The modifiers going down.
        case chord
        /// The whole shortcut down: recording.
        case held
        /// The modifiers let go, the letter held: still recording.
        case letterOnly
        /// Everything up: pasted.
        case done
    }

    /// Where the demo is `time` seconds in; it loops every `demoPeriod`.
    static func demoStep(at time: TimeInterval) -> DemoStep {
        let t = time.truncatingRemainder(dividingBy: demoPeriod)
        switch t {
        case ..<0.6: return .rest
        case ..<0.9: return .chord
        case ..<1.9: return .held
        case ..<3.9: return .letterOnly
        default: return .done
        }
    }

    /// The keys the demo has down at a step.
    static func demoKeys(_ step: DemoStep) -> (modifiersDown: Bool, letterDown: Bool) {
        switch step {
        case .rest, .done: return (false, false)
        case .chord: return (true, false)
        case .held: return (true, true)
        case .letterOnly: return (false, true)
        }
    }

    // Settings › Hold to talk draws each gesture as keys and what the dictation is
    // doing, one frame at a time: the hold above, the double tap and the switch below.

    /// What the dictation is doing in a demo frame.
    enum DemoState: Equatable {
        case idle, recording, locked, ai, pasted
    }

    /// One frame of a gesture demo: which keys are down — the shortcut's modifiers and
    /// letter, and for the switch the other shortcut — and what that does.
    struct DemoFrame: Equatable {
        var modifiersDown = false
        var letterDown = false
        var otherDown = false
        var state: DemoState = .idle
    }

    /// The hold, as a frame.
    static func holdFrame(at time: TimeInterval) -> DemoFrame {
        let step = demoStep(at: time)
        let keys = demoKeys(step)
        let state: DemoState = switch step {
        case .rest, .chord: .idle
        case .held, .letterOnly: .recording
        case .done: .pasted
        }
        return DemoFrame(modifiersDown: keys.modifiersDown, letterDown: keys.letterDown, state: state)
    }

    static let lockDemoPeriod: TimeInterval = 5.0

    /// The double tap: two quick presses lock the dictation on, nothing is held while it
    /// records, and the next press stops it.
    static func lockFrame(at time: TimeInterval) -> DemoFrame {
        let t = time.truncatingRemainder(dividingBy: lockDemoPeriod)
        let down = DemoFrame(modifiersDown: true, letterDown: true, state: .recording)
        switch t {
        case ..<0.6: return DemoFrame()
        case ..<0.8: return down
        case ..<0.95: return DemoFrame(state: .recording)
        case ..<1.15: return down
        case ..<3.6: return DemoFrame(state: .locked)
        case ..<3.8: return DemoFrame(modifiersDown: true, letterDown: true, state: .locked)
        default: return DemoFrame(state: .pasted)
        }
    }

    static let switchDemoPeriod: TimeInterval = 5.6

    /// The switch: the shortcut held, a tap of the other one turns the dictation into an
    /// AI Rewrite, a second tap turns it back, and letting go pastes.
    static func switchFrame(at time: TimeInterval) -> DemoFrame {
        let t = time.truncatingRemainder(dividingBy: switchDemoPeriod)
        let held = DemoFrame(modifiersDown: true, letterDown: true)
        func frame(_ state: DemoState, otherDown: Bool = false) -> DemoFrame {
            var frame = held
            frame.state = state
            frame.otherDown = otherDown
            return frame
        }
        switch t {
        case ..<0.5: return DemoFrame()
        case ..<0.8: return DemoFrame(modifiersDown: true)
        case ..<1.7: return frame(.recording)
        case ..<1.95: return frame(.ai, otherDown: true)
        case ..<3.0: return frame(.ai)
        case ..<3.25: return frame(.recording, otherDown: true)
        case ..<4.1: return frame(.recording)
        default: return DemoFrame(state: .pasted)
        }
    }
}
