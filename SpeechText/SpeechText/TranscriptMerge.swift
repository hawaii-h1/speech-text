// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Stitching

/// `head + " " + tail`, skipping the space when either side is empty. Both tiers stitch
/// their committed and in-progress text the same way.
func joinedTranscript(_ head: String, _ tail: String) -> String {
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    return head + " " + tail
}

// MARK: - Merging a realtime transcript onto what is already committed

/// Scribe's realtime stream does not always start a clean slate after a commit: the
/// partials that follow — and the next `committed_transcript` itself — can restate the
/// whole accumulated transcript, with its tail extended and its last words revised
/// ("… Що там узагалі нового? Це…" → "… Що там узагалі нового? Це нові задачі?").
/// Joining that onto what was already committed pastes the dictation twice, which is
/// exactly what the user sees. An exact-echo test does not catch it, because the
/// restatement has grown by the time it arrives.
///
/// So text arriving from a stream is *merged* rather than appended: whatever prefix of
/// it repeats what we already hold is dropped, and a restatement of everything replaces
/// it (the server's later version is the better one — it saw more audio).

/// One word of a transcript, normalised for comparison and anchored in its source.
/// Lowercased with the punctuation trimmed off both ends, so "Це…" and "Це" — the same
/// word before and after the server revised the sentence around it — compare equal.
struct TranscriptWord: Equatable {
    /// Lowercased, punctuation-stripped. Never empty.
    let text: String
    /// Where the word starts in the string it was read from.
    let start: String.Index
}

func transcriptWords(_ text: String) -> [TranscriptWord] {
    text.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
        let normalized = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard !normalized.isEmpty else { return nil }
        return TranscriptWord(text: normalized, start: token.startIndex)
    }
}

/// How much of `head` the start of `tail` repeats.
///
/// `words` is the number of words; `restatesHead` says the repeat covers all of `head`,
/// so `tail` is a fuller version of it rather than a continuation that happens to open
/// with the same words.
func transcriptOverlap(head: [TranscriptWord], tail: [TranscriptWord]) -> (words: Int, restatesHead: Bool) {
    guard !head.isEmpty, !tail.isEmpty else { return (0, false) }

    // A restatement of everything, allowing for the odd revised word: the server hears
    // the audio again with more context after it and rewrites a word or two, so an exact
    // prefix test would miss precisely the case that duplicates the dictation.
    if tail.count >= head.count, head[0].text == tail[0].text {
        let matches = zip(head, tail.prefix(head.count)).filter { $0.text == $1.text }.count
        if Double(matches) >= Double(head.count) * TranscriptMergeTuning.restatementAgreement {
            return (head.count, true)
        }
    }

    // Otherwise only an unmistakable repeat counts: a run long enough that the user
    // cannot plausibly have said those words twice across a segment boundary.
    let maximum = min(head.count, tail.count)
    guard maximum >= TranscriptMergeTuning.minimumRepeatedWords else { return (0, false) }
    for k in stride(from: maximum, through: TranscriptMergeTuning.minimumRepeatedWords, by: -1)
    where head.suffix(k).map(\.text) == tail.prefix(k).map(\.text) {
        return (k, false)
    }
    return (0, false)
}

enum TranscriptMergeTuning {
    /// Fraction of `head`'s words a restatement has to reproduce. Below 1.0 because the
    /// server revises words as it gains context; high enough that a genuinely new
    /// sentence opening with the same word is not mistaken for one.
    static let restatementAgreement = 0.8
    /// Shortest repeated run treated as an overlap rather than as speech. Four words of
    /// a partial repeating the tail of the committed text is the server re-sending;
    /// one or two is a person saying "так, так".
    static let minimumRepeatedWords = 4
}

/// `head` with `tail` merged onto it: the repeated opening of `tail` is dropped, and a
/// `tail` that restates all of `head` replaces it.
func mergedTranscript(_ head: String, _ tail: String) -> String {
    let headWords = transcriptWords(head)
    let tailWords = transcriptWords(tail)
    let overlap = transcriptOverlap(head: headWords, tail: tailWords)
    if overlap.restatesHead { return tail }
    return joinedTranscript(head, dropping(overlap.words, from: tail, words: tailWords))
}

/// The part of `text` that is not already in `committed` — what a partial adds to the
/// text the stream has committed so far. Empty when the partial is nothing but an echo.
func transcriptContinuation(of committed: String, in text: String) -> String {
    let committedWords = transcriptWords(committed)
    let textWords = transcriptWords(text)
    let overlap = transcriptOverlap(head: committedWords, tail: textWords)
    return dropping(overlap.words, from: text, words: textWords)
}

private func dropping(_ count: Int, from text: String, words: [TranscriptWord]) -> String {
    guard count > 0 else { return text }
    guard count < words.count else { return "" }
    return String(text[words[count].start...]).trimmingCharacters(in: .whitespacesAndNewlines)
}
