// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a paste landed in the target app: the range the text occupies, and the app's
/// own copy of that text. Both are read back out of the Accessibility API rather than
/// assumed from what was sent.
struct PasteLanding: Equatable {
    let range: NSRange
    /// What the app actually holds there — smart quotes applied, line endings
    /// normalised, whatever it did. The only version a later guard can compare to.
    let text: String
}

/// The I/O an inline dictation needs from the app it writes into. `AccessibilityDeliveryTarget`
/// answers it through `PasteService` in the app; a replay answers it with a document in
/// memory, which is what lets the whole delivery run without an app to focus.
protocol InlineDeliveryTarget: AnyObject {
    /// Accessibility is granted and the recording's target app is the one in front — a
    /// span may be pasted now.
    var acceptsDeliveryNow: Bool { get }
    /// Pastes `text` at the cursor. `completion` gets where it landed, or nil when that
    /// could not be established — which means only that the paste cannot be corrected.
    func paste(_ text: String, completion: @escaping (PasteLanding?) -> Void)
    /// Remembers the field that has focus now, so a correction at the stop can tell
    /// whether it would still be writing into the same one.
    func captureFocusedField()
    func releaseFocusedField()
    /// The field captured at the start is still focused, in the app in front.
    var isStillFocused: Bool { get }
    /// Replaces everything `ledger` recorded with `text`, in one write, and records it
    /// there. False, with the document untouched, when any step refuses.
    func replaceDelivered(ledger: inout InsertionLedger, with text: String) -> Bool
}

/// One inline recording's delivery into another app: which tier it runs in, the spans
/// pasted while the user speaks, the ledger of what landed where, the stop's one
/// correction, and what the stop still has to paste.
///
/// Pure logic, in both targets. `AppState` owns one, wires `SpeechEngine`'s span and
/// finalize callbacks into it, and keeps everything that is not a decision about text:
/// the overlay, the status notices, the Record Window fallback, the LLM call.
final class InlineDelivery {
    /// Decided once, when the recording starts, and never revisited: a tier that changed
    /// halfway would mean text issued under one set of rules being corrected under another.
    private(set) var tier: DeliveryTier = .c
    /// What has actually been pasted into the target app during this recording — the
    /// sink's own record, not the engine's. The stop subtracts it from the authoritative
    /// text so a dictation is never pasted twice.
    private(set) var ledger = InsertionLedger()
    /// Spans waiting their turn, and whether one is in flight. Pastes are serialised:
    /// two ⌘V in flight at once race over the pasteboard, and the second would stage its
    /// text before the first had been read.
    private var queue: [TranscriptSpan] = []
    private(set) var isDeliveringSpan = false
    /// Waiting for the paste in flight to land — see `whenIdle`.
    private var idleWaiters: [() -> Void] = []
    private var target: InlineDeliveryTarget?

    /// Starts a recording's delivery and says whether spans go out while the user is
    /// still speaking.
    func begin(tier: DeliveryTier, aiMode: Bool, aiDraft: Bool,
               target: InlineDeliveryTarget, targetName: String?) -> Bool {
        queue = []
        isDeliveringSpan = false
        resumeIdleWaiters()
        ledger.clear()
        self.tier = tier
        self.target = target

        let progressive = tier.deliversDuringRecording(aiMode: aiMode, aiDraft: aiDraft)
        dlog("Span", "tier \(tier) for \(targetName ?? "nil") — \(progressive ? "delivering during the recording" : "buffering until the stop")")
        if progressive && tier.recordsRanges {
            target.captureFocusedField()
        } else {
            target.releaseFocusedField()
        }
        return progressive
    }

    /// Stops offering spans. The ledger is kept: the stop still has to know what the
    /// app was given so it can hand over the rest and not the whole thing again.
    func stopOffering() {
        queue = []
    }

    /// The recording was abandoned. Nothing more goes out — including anything already
    /// queued — and the ledger goes with it. Text already pasted stays where it is:
    /// un-inserting it into a foreign app is not possible.
    func end() {
        stopOffering()
        target?.releaseFocusedField()
        ledger.clear()
        // Nobody waits on an abandoned recording's paste.
        resumeIdleWaiters()
    }

    // MARK: While the user speaks

    func enqueue(_ spans: [TranscriptSpan]) {
        queue.append(contentsOf: spans)
        drain()
    }

    /// Pastes one emission's worth of spans, then the next. Everything ready at once
    /// goes in a single ⌘V: one paste is one race with the target app instead of
    /// several, and the ranges still come out per span whenever the app stored the text
    /// exactly as it was handed it.
    private func drain() {
        guard !isDeliveringSpan, !queue.isEmpty, let target else { return }

        // Only into the app the recording was started in, and only while it is still the
        // one in front: the user may have switched away mid-dictation, and text pasted
        // into whatever they switched to is worse than text delivered late. The spans stay
        // queued, in order, and go out with the next ones once the app is back in front —
        // or, if it never is, the stop delivers them itself. Dropping them instead pasted
        // the next sentence straight after the gap, and a stop that only looks at the end
        // of what was delivered found nothing missing: the words were in History alone.
        guard target.acceptsDeliveryNow else {
            dlog("Span", "not delivering now — the target app is not in front; the stop will")
            return
        }

        let spans = queue
        queue = []

        let delivering = spans.filter { !$0.text.isEmpty }
        guard let first = delivering.first else { return }
        let joined = joinedSpanTexts(delivering)
        // What separates this delivery from the last — a space, or nothing when the
        // provider cut a word across the two.
        let payload = ledger.isEmpty ? joined : first.separator + joined

        isDeliveringSpan = true
        target.paste(payload) { [weak self] landing in
            guard let self else { return }
            self.isDeliveringSpan = false
            self.record(delivering, payload: payload, landing: landing)
            self.drain()
            if !self.isDeliveringSpan { self.resumeIdleWaiters() }
        }
    }

    /// Runs `body` once no paste is in flight — at once when none is.
    ///
    /// The stop's result waits here. A span pasted just before the stop has not reached
    /// the ledger until its landing is read back (up to half a second), and a remainder
    /// computed before then counts those words as not delivered and pastes them again.
    func whenIdle(_ body: @escaping () -> Void) {
        guard isDeliveringSpan else {
            body()
            return
        }
        idleWaiters.append(body)
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    /// Writes what went out into the ledger. Per span where the app stored exactly what
    /// it was handed — those ranges are what the finalizing pass replaces through — and
    /// as one untracked piece otherwise, which still answers what the stop asks of the
    /// ledger (what has this app already been given?) but can never be corrected.
    private func record(_ spans: [TranscriptSpan], payload: String, landing: PasteLanding?) {
        let joined = joinedSpanTexts(spans)
        let joinsLedger = !ledger.isEmpty && spans.first?.joinsPrevious == true

        // Per span only when the app stored exactly what it was handed. Anything else —
        // it normalised the text, or the landing could not be read — and the offsets
        // would be fiction, so it goes down as one untracked piece instead.
        guard let landing, tier.recordsRanges, landing.text == payload else {
            if landing == nil {
                dlog("Span", "delivered \(spans.map(\.id.description).joined(separator: " ")), landing unknown")
            }
            ledger.insert(span: nil, range: NSRange(location: NSNotFound, length: 0),
                          text: joined, joinsPrevious: joinsLedger)
            return
        }

        // The payload may open with the separator from the last delivery.
        var location = landing.range.location + (payload as NSString).length - (joined as NSString).length
        for (index, span) in spans.enumerated() {
            if index > 0 { location += (span.separator as NSString).length }
            let length = (span.text as NSString).length
            ledger.insert(span: span.id,
                          range: NSRange(location: location, length: length),
                          text: span.text,
                          joinsPrevious: index == 0 ? joinsLedger : span.joinsPrevious)
            location += length
        }
    }

    // MARK: At the stop

    /// The finalizing pass: what the app was given during the recording is brought in
    /// line with the authoritative text by one write, or left exactly as it is. Runs
    /// before the engine goes idle, so the stop's paste sees the ledger as the pass left
    /// it — after a correction there is nothing more to paste.
    ///
    /// Returns whether a correction was applied, or nil when none was called for (nothing
    /// delivered, or the final text only adds to it) — the value History's
    /// `correctionApplied` takes.
    func finalize(text: String, hasFrozenSpans: Bool) -> Bool? {
        let decision = FinalizePass.decide(ledger: ledger, authoritative: text,
                                           tier: tier, hasFrozenSpans: hasFrozenSpans)
        dlog("Span", "finalize: \(decision), tier \(tier)")

        switch decision {
        case .nothingDelivered, .extend:
            // The stop's ordinary paste is the one write.
            return nil
        case .leave:
            return false
        case .replace:
            return correctDeliveredText(to: text)
        }
    }

    private func correctDeliveredText(to text: String) -> Bool {
        // A paste still in flight has not reached the ledger: the plan would replace the
        // text before it and leave it standing after the correction — the words twice.
        guard !isDeliveringSpan else {
            dlog("Span", "finalize: a delivery is still landing — not correcting")
            return false
        }
        // The tier is checked again: it was decided for one field of one app.
        guard let target, target.isStillFocused else {
            dlog("Span", "finalize: the app or the focused field changed since the recording started — not correcting")
            return false
        }
        return target.replaceDelivered(ledger: &ledger, with: text)
    }

    /// What the stop still has to paste, with everything already delivered taken off the
    /// front — or nil when the final text disagrees with what was delivered. The deciding
    /// is `InsertionLedger.pasteableRemainder`; this logs what it decided.
    func undeliveredRemainder(of authoritative: String) -> String? {
        let delivered = ledger.deliveredText
        guard !delivered.isEmpty else { return authoritative }

        guard let remainder = ledger.pasteableRemainder(of: authoritative) else {
            dlog("Span", "final text does not extend the \(delivered.count) chars already delivered — delivering nothing more")
            return nil
        }
        dlog("Span", "already delivered \(delivered.count) chars; \(remainder.count) left to paste\(remainder.first.map { !$0.isWhitespace } == true && !remainder.isEmpty ? " (joins the last word)" : "")")
        return remainder
    }

    /// What a stop's result comes to, once the engine has gone idle.
    enum StopResult: Equatable {
        /// The transcription failed. `partial` is whatever of it was not delivered yet,
        /// for the Record Window; nil or empty when there is nothing to hand over.
        case failed(partial: String?)
        /// Nothing was transcribed and nothing was delivered.
        case noSpeech
        /// The final text came back empty, but the dictation is already in the document.
        case alreadyDelivered
        /// The final text re-words what was delivered too much to tell where it ends —
        /// nothing more is pasted, and the user is told.
        case notPasted
        /// Everything was already pasted as it was committed.
        case nothingLeft
        case paste(String)
        /// AI mode: rewrite `input`, then hand the result to `deliverAIResult`.
        case refine(input: String)
    }

    /// The stop's decision, given the engine's final text.
    ///
    /// `recordingText` is the whole recording's text (`spanLayer.text`): a draft already
    /// in the document covers every segment and the rewrite replaces all of it, so it has
    /// to be a rewrite of all of it — `finalText` holds only the last segment after a
    /// device restart.
    func stopResult(finalText: String, failed: Bool, aiMode: Bool, recordingText: String) -> StopResult {
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Spans pasted while the user was still speaking are already in the document.
        // `finalize` has already corrected them where it could, which leaves nothing
        // here. Nil means the final text still disagrees with them — the correction was
        // refused — and a second wording is not pasted under the first.
        let remainder = undeliveredRemainder(of: text)

        if failed {
            return .failed(partial: remainder)
        }
        guard !text.isEmpty else {
            // Unless the recording already delivered: a stream that committed words and
            // then fell back to a batch upload which came back empty leaves the dictation
            // sitting in the user's document, and telling them nothing was transcribed
            // while they are looking at it is worse than saying nothing.
            return ledger.deliveredText.isEmpty ? .noSpeech : .alreadyDelivered
        }
        guard !aiMode else {
            return .refine(input: ledger.isEmpty ? text : recordingText)
        }
        guard let remainder else { return .notPasted }
        return remainder.isEmpty ? .nothingLeft : .paste(remainder)
    }

    /// Where an AI dictation's final text goes: `paste` is what the stop still pastes
    /// (nil for nothing), `correctionApplied` what History records (nil when no
    /// correction was called for).
    ///
    /// With nothing delivered early, the ordinary paste. With a draft already in the
    /// document (`aiDraftWhileSpeaking`), the result replaces it in one write — or, when
    /// the result only adds to the draft (a failed rewrite falls back to the raw
    /// transcript, which usually does), the rest is pasted after it. A refused
    /// replacement pastes the result anyway: that is the user's call, getting the
    /// rewrite in matters more to them than the draft staying out of the way, so the
    /// document may then hold both.
    func deliverAIResult(_ output: String, hasFrozenSpans: Bool) -> (paste: String?, correctionApplied: Bool?) {
        guard !ledger.isEmpty else { return (output, nil) }

        let decision = FinalizePass.decide(ledger: ledger, authoritative: output, tier: tier,
                                           hasFrozenSpans: hasFrozenSpans)
        dlog("Span", "AI draft: \(decision)")

        switch decision {
        case .nothingDelivered:
            return (output, nil)
        case .extend:
            guard let rest = ledger.pasteableRemainder(of: output), !rest.isEmpty else { return (nil, nil) }
            return (rest, nil)
        case .replace, .leave:
            let applied = decision == .replace && correctDeliveredText(to: output)
            guard !applied else { return (nil, true) }
            dlog("Span", "AI draft could not be replaced — pasting the AI result as well")
            // After the draft, so separated from it like any other delivery.
            return (ledger.separated(output), false)
        }
    }
}
