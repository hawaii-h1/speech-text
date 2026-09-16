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
        records.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func record(for span: TranscriptSpanID) -> InsertionRecord? {
        records.last { $0.span == span }
    }

    // MARK: Writing

    /// Text landed at `range`. Records made earlier that sit at or after it move by its
    /// length — the user can put the caret anywhere between two insertions.
    mutating func insert(span: TranscriptSpanID?, range: NSRange, text: String) {
        shift(from: range.location, by: range.length)
        records.append(InsertionRecord(span: span, range: range, text: text))
    }

    /// A span's text was replaced in the sink. Its own record takes the new text, and
    /// everything after it moves by the difference.
    mutating func replaced(span: TranscriptSpanID, at range: NSRange, with text: String) {
        guard let index = records.lastIndex(where: { $0.span == span }) else { return }
        let new = NSRange(location: range.location, length: (text as NSString).length)
        let delta = new.length - range.length
        records[index].range = new
        records[index].text = text
        for other in records.indices where other != index && records[other].range.location >= range.location + range.length {
            records[other].range.location += delta
        }
    }

    mutating func clear() { records = [] }

    private mutating func shift(from location: Int, by delta: Int) {
        guard delta != 0 else { return }
        for index in records.indices where records[index].range.location >= location {
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

        let overlap = transcriptOverlap(head: transcriptWords(delivered),
                                        tail: transcriptWords(authoritative))
        guard overlap.words > 0 else { return nil }
        return transcriptContinuation(of: delivered, in: authoritative)
    }

    /// Where this span's text is in `document` *right now*, or nil if it is not there
    /// untouched. Three steps, in the order phase C's spec asks for them: the recorded
    /// range if the substring still matches exactly; otherwise the last occurrence of
    /// that text anywhere in the document (it moved — the user typed above it);
    /// otherwise nothing at all, and the caller must leave the document alone.
    func resolve(span: TranscriptSpanID, in document: String) -> NSRange? {
        guard let record = record(for: span), !record.text.isEmpty else { return nil }
        let text = document as NSString

        if NSMaxRange(record.range) <= text.length,
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
