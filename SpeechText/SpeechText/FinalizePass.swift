// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One write into a sink: select `range`, put `text` there.
struct TextReplacement: Equatable {
    let range: NSRange
    let text: String
}

/// The stop's one decision about text a recording already handed to a sink (D12): the
/// authoritative text arrives once, and whatever the sink holds is brought in line with
/// it by *one* write — or not touched at all.
///
/// Pure logic, in both targets. The I/O is `PasteService.replaceLastInsertions`, which
/// reads the document out of the Accessibility API and hands it in here; everything that
/// decides whether and where to write is below, where `PureLogicTests` can reach it.
enum FinalizePass {
    enum Decision: Equatable {
        /// Nothing was delivered during the recording: the stop pastes the whole text,
        /// which is already the one write. AI mode and Tier C always land here.
        case nothingDelivered
        /// What the sink holds is the authoritative text, or its opening words: the stop
        /// pastes the rest after it (possibly nothing). No correction is needed.
        case extend
        /// The authoritative text disagrees with what the sink holds, and the sink can be
        /// corrected: replace the delivered text with it, in one write.
        case replace
        /// It disagrees, and the sink cannot be corrected — Tier B, untracked pieces, text
        /// the user has frozen, or an empty result. The delivered text stands as it is.
        case leave
    }

    /// What the stop does with the text already delivered.
    ///
    /// `hasFrozenSpans`: the user edited this recording's text by hand, and nothing
    /// rewrites that — so a disagreement is left standing rather than corrected.
    static func decide(ledger: InsertionLedger,
                       authoritative: String,
                       tier: DeliveryTier,
                       hasFrozenSpans: Bool) -> Decision {
        let delivered = ledger.deliveredText
        guard !delivered.isEmpty else { return .nothingDelivered }

        let final = authoritative.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty result against delivered spans is not a correction into nothing.
        guard !final.isEmpty else { return .leave }
        if extendsExactly(delivered, final) { return .extend }

        // Records without a range are not a refusal here: `plan` looks them up by their
        // text and refuses there if any is not found exactly once.
        guard tier.recordsRanges, !hasFrozenSpans else { return .leave }
        return .replace
    }

    /// Where the delivered text is in `document` right now, as one range, and what goes
    /// there. Nil — leave the document alone — unless every step checks out:
    ///
    /// 1. Every record resolves (`InsertionLedger.resolve`): at its recorded range, or as
    ///    the one unambiguous occurrence of its text — which is also how a paste whose
    ///    landing could not be read is found. The spec lets an unresolvable
    ///    record be *skipped*; here it refuses the whole pass instead, because the write
    ///    is a single range across all records, and a skipped one inside it is text the
    ///    user changed that the write would overwrite — and a skipped one at an end is
    ///    words the replacement would put into the document a second time.
    /// 2. The resolved records sit next to each other, with nothing but whitespace
    ///    between them — what the sink inserted as separators. Anything else between two
    ///    records is the user's typing, and it is not ours to replace.
    static func plan(ledger: InsertionLedger, document: String, replacement: String) -> TextReplacement? {
        guard !ledger.isEmpty else { return nil }
        let text = document as NSString

        var ranges: [NSRange] = []
        for record in ledger.records {
            guard let range = ledger.resolve(record, in: document) else { return nil }
            ranges.append(range)
        }
        ranges.sort { $0.location < $1.location }

        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            let gapStart = NSMaxRange(previous)
            guard next.location >= gapStart else { return nil } // overlapping records
            let gap = text.substring(with: NSRange(location: gapStart, length: next.location - gapStart))
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
        }

        let first = ranges[0], last = ranges[ranges.count - 1]
        let covering = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let final = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty, text.substring(with: covering) != final else { return nil }
        return TextReplacement(range: covering, text: final)
    }

    /// `delivered` is word for word the opening of `final` — the stop only has to add to
    /// it. Exact, unlike `transcriptOverlap`: a word the provider revised is precisely
    /// what a correction exists for, so it must not pass as agreement.
    static func extendsExactly(_ delivered: String, _ final: String) -> Bool {
        let head = words(delivered), all = words(final)
        return all.count >= head.count && Array(all.prefix(head.count)) == head
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }
}

extension InsertionLedger {
    /// The sink now holds `replacement.text` over `replacement.range`, in place of every
    /// record: one record remains, untracked by span (the spans it came from no longer
    /// map onto it piece by piece), so a later `remainder(of:)` subtracts all of it.
    mutating func collapse(into replacement: TextReplacement, landed text: String) {
        clear()
        insert(span: nil, range: NSRange(location: replacement.range.location,
                                         length: (text as NSString).length),
               text: text)
    }
}
