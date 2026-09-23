// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What an inline dictation's stop does with the engine's final text.
///
/// Nothing is handed to another app while the user speaks: the text is built on the
/// overlay, where the provider can still re-punctuate and re-word it, and the stop pastes
/// it once. There is therefore no ledger to subtract, no correction to make and no draft
/// to replace — which is what used to fill this file, when committed spans were pasted
/// into the target app as they arrived (#75).
///
/// Pure logic, in both targets. `AppState` asks it where the dictation goes when the user
/// stops, and what to do with the text once the engine has gone idle; it keeps everything
/// that is not a decision: the overlay, the status notices, the Record Window fallback,
/// the LLM call, the paste itself.
enum InlineDelivery {
    /// Where an inline dictation is pasted: the app in front when the user stopped, in
    /// whatever app that is — not the one it started in (#77). With nothing to paste
    /// before the stop there is nothing spread across two apps, so the only question is
    /// where the one paste goes, and the answer is where the user is.
    ///
    /// Fixed at the stop, never re-read at the paste: an AI rewrite takes seconds, the
    /// user may move again meanwhile, and the app they stopped in is re-activated for the
    /// paste — so the prompt's `<context>` and the destination are always the same app.
    ///
    /// SpeechText's own window in front (Settings, History) is not a destination — the
    /// app never pastes into itself — so the dictation goes where it started, and with no
    /// origin either, to the Record Window.
    ///
    /// Generic so the replay resolves its fake apps through the same rule.
    static func destination<App>(front: App?, frontIsSpeechText: Bool, origin: App?) -> App? {
        guard let front, !frontIsSpeechText else { return origin }
        return front
    }

    /// What a stop's result comes to, once the engine has gone idle.
    enum StopResult: Equatable {
        /// The transcription failed. `partial` is whatever text there was, for the
        /// Record Window; nil or empty when there is nothing to hand over.
        case failed(partial: String?)
        /// Nothing was transcribed.
        case noSpeech
        case paste(String)
        /// AI mode: rewrite `input`, then paste the result.
        case refine(input: String)
    }

    /// The stop's decision, given the engine's final text.
    ///
    /// `recordingText` is the whole recording's text (`spanLayer.text`), which is what is
    /// pasted or rewritten: `finalText` holds only the last segment after a device
    /// restart closed one mid-dictation, and pasting it alone dropped everything said
    /// before. An empty final text keeps its meaning — the span layer is empty too, or
    /// holds ghost text a failed stream took back.
    static func stopResult(finalText: String, failed: Bool, aiMode: Bool, recordingText: String) -> StopResult {
        let last = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = recordingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = last.isEmpty || whole.isEmpty ? last : whole

        if failed {
            // With no final text, what the recording did show is still worth handing to
            // the Record Window: a stream that committed words and then broke, with an
            // upload that failed too, had those words on the overlay — and, before #75,
            // in the document.
            return .failed(partial: text.isEmpty ? whole : text)
        }
        guard !text.isEmpty else { return .noSpeech }
        return aiMode ? .refine(input: text) : .paste(text)
    }
}
