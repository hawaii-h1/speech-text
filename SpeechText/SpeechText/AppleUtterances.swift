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
///   moves into `settled` (`isNewUtterance` says what "continue" means).
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
    ///
    /// A word that begins like the first word is not enough on its own, since a short one
    /// begins half the language: after "I went to the store" and a pause, "It" is a new
    /// sentence, and so is "Але" after "А ми вже вдома". So a word grown or shrunk counts as
    /// the same only while the result spells at least half as many letters as the one it
    /// would replace: the same audio heard again ("За ми" → "Завтра", "I am" → "I'm")
    /// spells about as much, a new utterance starts with a word or two.
    static func isNewUtterance(_ incoming: String, after current: String) -> Bool {
        let old = transcriptWords(current), new = transcriptWords(incoming)
        guard old.count >= 2, let first = old.first?.text, let next = new.first?.text,
              new.count < old.count, first != next else { return false }
        guard first.hasPrefix(next) || next.hasPrefix(first) else { return true }
        return letters(in: new) * 2 < letters(in: old)
    }

    private static func letters(in words: [TranscriptWord]) -> Int {
        words.reduce(0) { $0 + $1.text.count }
    }
}
