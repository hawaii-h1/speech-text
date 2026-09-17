// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where one span's text landed in a sink, and what the sink actually holds there.
///
/// `text` is deliberately *the sink's* copy, not the string we sent: a text view with
/// smart quotes on, or a foreign app that normalises line endings, stores something
/// slightly different from what was pasted. The finalizing pass (phase C) guards on
/// "is what I inserted still there, untouched", and that guard has to compare against
/// the document's version or it refuses every correction it is asked to make.
struct InsertionRecord: Equatable {
    /// The span this text came from. `nil` for text a sink was handed that the span
    /// layer could not account for — it is tracked for offsets, never rewritten.
    let span: TranscriptSpanID?
    /// UTF-16 range, because every sink this talks to (`NSTextView`, the AX API) is
    /// UTF-16 indexed.
    var range: NSRange
    var text: String
    /// Pasted straight onto the previous record, with no space — the provider cut a word.
    var joinsPrevious = false
}

/// The record of what has already been handed to one sink during a recording, so a
/// later pass can find its own text again and replace exactly that.
///
/// Pure logic — no text view, no AX, no app state. The sinks (`TextInsertionHandler`
/// for the Record Window, `AppState` for inline) own the I/O and keep one of these;
/// the deciding is here, where `PureLogicTests` can reach it.
struct InsertionLedger {
    private(set) var records: [InsertionRecord] = []

    init() {}

    var isEmpty: Bool { records.isEmpty }

    /// Everything handed to the sink so far, joined the way spans join. What a stop-time
    /// delivery has to subtract before it hands over the authoritative text.
    var deliveredText: String {
        var text = ""
        for record in records where !record.text.isEmpty {
            text += text.isEmpty ? record.text : (record.joinsPrevious ? "" : " ") + record.text
        }
        return text
    }

    func record(for span: TranscriptSpanID) -> InsertionRecord? {
        records.last { $0.span == span }
    }

    // MARK: Writing

    /// Text landed at `range`. Records made earlier that sit at or after it move by its
    /// length — the user can put the caret anywhere between two insertions.
    mutating func insert(span: TranscriptSpanID?, range: NSRange, text: String, joinsPrevious: Bool = false) {
        shift(from: range.location, by: range.length)
        records.append(InsertionRecord(span: span, range: range, text: text, joinsPrevious: joinsPrevious))
    }

    /// A span's text was replaced in the sink. Its own record takes the new text, and
    /// everything after it moves by the difference.
    mutating func replaced(span: TranscriptSpanID, at range: NSRange, with text: String) {
        guard let index = records.lastIndex(where: { $0.span == span }) else { return }
        let new = NSRange(location: range.location, length: (text as NSString).length)
        let delta = new.length - range.length
        records[index].range = new
        records[index].text = text
        for other in records.indices where other != index
            && records[other].range.location != NSNotFound
            && records[other].range.location >= range.location + range.length {
            records[other].range.location += delta
        }
    }

    mutating func clear() { records = [] }

    /// A record with no range (`NSNotFound`, a paste whose landing could not be read) has
    /// no position to move — and `NSNotFound` is `Int.max`, so moving it would trap.
    private mutating func shift(from location: Int, by delta: Int) {
        guard delta != 0, location != NSNotFound else { return }
        for index in records.indices
        where records[index].range.location != NSNotFound && records[index].range.location >= location {
            records[index].range.location += delta
        }
    }

    // MARK: Reading

    /// What is left of `authoritative` once everything already delivered is taken off
    /// the front — what a stop still has to hand over.
    ///
    /// Nil means "deliver nothing more": the authoritative text does not extend what the
    /// sink already holds, it disagrees with it. The realistic cause is a streaming
    /// segment that fell back to a batch upload and came back worded differently. The
    /// finalizing pass corrects that where the app allows it; where it refused, pasting
    /// the second wording underneath the first is worse than leaving the first
    /// standing — a dictation the user has to re-read and de-duplicate by hand.
    func remainder(of authoritative: String) -> String? {
        let delivered = deliveredText
        guard !delivered.isEmpty else { return authoritative }

        let head = transcriptWords(delivered)
        let tail = transcriptWords(authoritative)
        let overlap = transcriptOverlap(head: head, tail: tail)
        if overlap.words > 0 {
            return transcriptContinuation(of: delivered, in: authoritative)
        }
        return revisedContinuation(head: head, tail: tail, in: authoritative)
    }

    /// The tail of `text` after a re-wording of what was delivered — or nil if it is not
    /// one.
    ///
    /// `transcriptOverlap` recognises a restatement only when it opens with the same
    /// word, and a provider that heard the whole recording again revises exactly the
    /// words it was least sure of, the first among them ("Зроблю…" → "Роблю…"). Refusing
    /// there left the sentence said *after* the delivered text unpasted, in History and
    /// nowhere else. So this finds where the delivered words end inside `text` by their
    /// longest common subsequence, and accepts it only when that keeps the same
    /// `restatementAgreement` share of them in order — a re-wording, not a different
    /// dictation. The seam can be a word off; a lost sentence cannot be seen at all.
    private func revisedContinuation(head: [TranscriptWord], tail: [TranscriptWord], in text: String) -> String? {
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        let rows = head.count, columns = tail.count

        // lcs[i][j]: common subsequence of head[..<i] and tail[..<j].
        var lcs = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for i in 1...rows {
            for j in 1...columns {
                lcs[i][j] = head[i - 1].text == tail[j - 1].text
                    ? lcs[i - 1][j - 1] + 1
                    : max(lcs[i - 1][j], lcs[i][j - 1])
            }
        }

        let best = lcs[rows][columns]
        guard best > 0,
              Double(best) >= Double(rows) * TranscriptMergeTuning.restatementAgreement else { return nil }

        // The shortest prefix of `tail` that already holds every match…
        var end = (0...columns).first { lcs[rows][$0] == best } ?? columns
        // …plus the delivered words after the last match, which were revised into the
        // tail's words that follow it rather than dropped.
        var i = rows, j = end
        var lastMatchedHead = -1
        while i > 0, j > 0 {
            if head[i - 1].text == tail[j - 1].text {
                lastMatchedHead = i - 1
                break
            } else if lcs[i - 1][j] >= lcs[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        end = min(columns, end + (rows - 1 - lastMatchedHead))

        guard end < columns else { return "" }
        return String(text[tail[end].start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exactly what the stop still pastes: `remainder(of:)` with its separator in front,
    /// or nil for "nothing — the final text disagrees".
    ///
    /// When the final text starts with the delivered text character for character, the
    /// rest is cut off it as it stands, so the separator is the provider's own — a space,
    /// or none after a word it cut ("…база дани" + "х, звідки…"). Only a re-worded
    /// final text goes through the word-level `remainder`, and that always takes a space.
    func pasteableRemainder(of authoritative: String) -> String? {
        let delivered = deliveredText
        guard !delivered.isEmpty else { return authoritative }

        let final = authoritative.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.hasPrefix(delivered) {
            let rest = final.dropFirst(delivered.count)
            guard let first = rest.first else { return "" }
            return first.isWhitespace
                ? " " + rest.trimmingCharacters(in: .whitespacesAndNewlines)
                : String(rest)
        }
        return remainder(of: authoritative).map(separated)
    }

    /// `rest` as it has to be pasted after what the sink already holds: opened with the
    /// space that separates it, the way every delivery during the recording opens with
    /// one. Without it the stop's tail lands glued to the last span ("Поїха.Ііі…").
    func separated(_ rest: String) -> String {
        guard !rest.isEmpty, !deliveredText.isEmpty else { return rest }
        return " " + rest
    }

    /// Where this span's text is in `document` *right now*, or nil if it is not there
    /// untouched. Three steps, in the order phase C's spec asks for them: the recorded
    /// range if the substring still matches exactly; otherwise the last occurrence of
    /// that text anywhere in the document (it moved — the user typed above it);
    /// otherwise nothing at all, and the caller must leave the document alone.
    func resolve(span: TranscriptSpanID, in document: String) -> NSRange? {
        guard let record = record(for: span) else { return nil }
        return resolve(record, in: document)
    }

    /// The same three steps for any record — including one with no span and no range,
    /// a paste whose landing could not be read. It skips straight to the search, and the
    /// search still refuses text that is not there exactly once.
    func resolve(_ record: InsertionRecord, in document: String) -> NSRange? {
        guard !record.text.isEmpty else { return nil }
        let text = document as NSString

        if record.range.location != NSNotFound,
           NSMaxRange(record.range) <= text.length,
           text.substring(with: record.range) == record.text {
            return record.range
        }

        let found = text.range(of: record.text, options: .backwards)
        guard found.location != NSNotFound else { return nil }
        // Ambiguous: the same words appear more than once, so "the last occurrence" is a
        // guess, and a guess is not allowed to rewrite the user's document.
        let head = NSRange(location: 0, length: found.location)
        guard text.range(of: record.text, options: .backwards, range: head).location == NSNotFound else {
            return nil
        }
        return found
    }
}
