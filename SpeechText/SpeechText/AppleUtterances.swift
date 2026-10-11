// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What Apple's on-device recogniser has said during one request, kept across the two
/// ways its results lose words (#175, found by the e2e harness):
///
/// - **A reset after a pause.** Once the speaker pauses, the recogniser starts a new
///   utterance, and the partials that follow hold only the new words ("Завтра ми поїдемо
///   до моря" → "Якщо"). Taken as a revision, the earlier sentence is gone. A partial that
///   does not continue the one before it is therefore a new utterance, and the earlier one
///   moves into `settled`.
/// - **An empty final.** At `endAudio()` the recogniser can answer `isFinal` with no text
///   at all, after partials that had plenty. An empty result never erases words already
///   heard.
///
/// Pure logic, in both targets, so the rules are tested without `Speech`.
struct AppleUtterances: Equatable {
    /// Utterances the recogniser has moved past.
    private(set) var settled = ""
    /// The utterance in progress, as the latest partial spells it.
    private(set) var current = ""

    var text: String { joinedTranscript(settled, current) }

    /// Takes one result's `formattedString`.
    mutating func receive(_ result: String) {
        let incoming = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        if let rest = Self.continuation(of: settled, in: incoming) {
            // A result that spells the earlier utterances again: only what it adds is the
            // current one. `settled` is never shortened — it is committed text, and the
            // span layer only ever extends that.
            current = rest
            return
        }
        if Self.isNewUtterance(incoming, after: current) {
            settled = joinedTranscript(settled, current)
        }
        current = incoming
    }

    /// What `incoming` adds when it begins with every word of `settled`; nil otherwise.
    static func continuation(of settled: String, in incoming: String) -> String? {
        let held = transcriptWords(settled).map(\.text), new = transcriptWords(incoming)
        guard !held.isEmpty, new.count > held.count,
              new.prefix(held.count).map(\.text) == held else { return nil }
        return String(incoming[new[held.count].start...])
    }

    /// A revision keeps the utterance's first word, or a word it grows from or into
    /// ("Кова" → "Коваленко"), and a reset starts shorter than the utterance it follows.
    /// Both must fail before words are kept as a separate utterance: taking a revision for
    /// a reset would paste its words twice.
    static func isNewUtterance(_ incoming: String, after current: String) -> Bool {
        let old = transcriptWords(current), new = transcriptWords(incoming)
        guard old.count >= 2, let first = old.first?.text, let next = new.first?.text,
              new.count < old.count else { return false }
        return !(first.hasPrefix(next) || next.hasPrefix(first))
    }
}
