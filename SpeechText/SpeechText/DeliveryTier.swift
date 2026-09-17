// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the Accessibility API will actually let us do to the focused text element.
///
/// Read-back is the load-bearing field. Chromium and Electron answer `.success` to a
/// selected-range *write* and then hand back a different range when asked, so anything
/// that trusts the return code alone classifies VS Code and Slack as correctable and
/// then scribbles over the user's text.
struct AXTextProbe: Equatable {
    /// `kAXValueAttribute` could be read as a string.
    var valueReadable: Bool = false
    /// `kAXSelectedTextRangeAttribute` could be read.
    var rangeReadable: Bool = false
    /// Writing it was accepted *and* reading it back returned what was written.
    var rangeReadsBack: Bool = false

    /// Nothing is known — no accessibility permission, or no focused element at all.
    static let unavailable = AXTextProbe()

    /// Everything phase C needs to find its own text again and re-select it.
    var supportsReplacement: Bool { valueReadable && rangeReadable && rangeReadsBack }
}

/// Which sink this recording is delivering into. Decided once, at the start of the
/// recording, and never revisited — a tier that changed halfway would mean text already
/// issued under one set of rules being corrected under another.
///
/// Pure logic, so the decision is testable without an app to focus: `PasteService` does
/// the Accessibility I/O and hands the answers in as an `AXTextProbe`.
enum DeliveryTier: String, Equatable, CustomStringConvertible {
    /// Our own surface, or a foreign app whose text the Accessibility API can read and
    /// re-select. Issued text can be found again and replaced.
    case a
    /// A foreign app we can paste into but cannot correct: Chromium and Electron, which
    /// answer inconsistently for `contenteditable`, and terminals, which never answer at
    /// all. Only committed text goes here, and it is never rewritten.
    case b

    var description: String {
        switch self {
        case .a: return "A (correctable)"
        case .b: return "B (append-only)"
        }
    }

    /// The spec's decision tree, in order: our own surface needs no probing, and a
    /// foreign app is Tier A only if it proved it.
    static func resolve(isOwnSurface: Bool, probe: AXTextProbe) -> DeliveryTier {
        if isOwnSurface { return .a }
        return probe.supportsReplacement ? .a : .b
    }

    /// Whether committed spans are handed over while the user is still speaking.
    ///
    /// AI mode buffers by default: the LLM rewrites the whole dictation, so text issued
    /// during the recording has to be taken back at the stop. `aiDraft` (the user's
    /// opt-in) lifts that in Tier A only, the one tier where the raw draft can be replaced
    /// by the rewrite; in Tier B the draft would stay under the rewrite, two versions of
    /// one dictation.
    func deliversDuringRecording(aiMode: Bool, aiDraft: Bool = false) -> Bool {
        switch self {
        case .a: return !aiMode || aiDraft
        case .b: return !aiMode
        }
    }

    /// Whether the sink is worth keeping an `InsertionLedger` for. Tier B cannot be
    /// corrected, so recording ranges there would only be bookkeeping for a pass that
    /// will always refuse to run.
    var recordsRanges: Bool { self == .a }
}
