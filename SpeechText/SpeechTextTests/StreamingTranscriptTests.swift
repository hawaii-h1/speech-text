// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

// MARK: - Realtime stream echo suppression (StreamingTranscribers.swift)

final class RealtimeEchoTests: XCTestCase {

    /// The bug this guards: Scribe follows its own `committed_transcript` with one more
    /// `partial_transcript` carrying the same words. Joined onto the committed text it
    /// pastes the dictation twice.
    func testPartialRepeatingTheCommittedSegmentIsAnEcho() {
        XCTAssertTrue(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(
            partial: "Проаналізуй результати тесту.",
            lastCommitted: "Проаналізуй результати тесту."))
    }

    func testEchoComparisonIgnoresSurroundingWhitespace() {
        XCTAssertTrue(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(
            partial: "  Hello there. ", lastCommitted: "Hello there."))
    }

    func testAGrowingNextSegmentIsNotAnEcho() {
        // Prefixes of the committed text are how a genuine new segment starts.
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(
            partial: "Проаналізуй", lastCommitted: "Проаналізуй результати тесту."))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(
            partial: "Проаналізуй результати тесту. І ще", lastCommitted: "Проаналізуй результати тесту."))
    }

    func testEmptyPartialOrNoCommitYetIsNotAnEcho() {
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(partial: "", lastCommitted: ""))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(partial: "   ", lastCommitted: "Hello."))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.isEchoOfCommitted(partial: "Hello.", lastCommitted: ""))
    }
}

// MARK: - Transcript span layer (TranscriptSpan.swift)

/// The layer is pure logic — no engine, no clock, no defaults — so the whole state
/// machine is exercised here: ordering, a partial being superseded, and the one rule
/// nothing may break, that a span the user touched is never rewritten.
final class TranscriptSpanLayerTests: XCTestCase {

    func testPartialIsOneSpanThatKeepsItsIdentityWhileItGrows() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "", partial: "Привіт")
        let first = layer.visibleSpans.first?.id
        layer.ingest(committed: "", partial: "Привіт, як")

        XCTAssertEqual(layer.visibleSpans.count, 1)
        XCTAssertEqual(layer.visibleSpans.first?.id, first)
        XCTAssertEqual(layer.segmentText, "Привіт, як")
        // Nothing has settled yet: a Tier B sink would receive nothing at all.
        XCTAssertEqual(layer.segmentStableText, "")
        XCTAssertEqual(layer.segmentProvisionalText, "Привіт, як")
    }

    /// The commit that follows a partial is *that* partial, so the span keeps its id —
    /// a sink that already drew it can replace it instead of appending a second copy.
    func testCommitAdoptsThePartialSpan() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "", partial: "Привіт, як справи")
        let id = layer.visibleSpans.first!.id
        layer.ingest(committed: "Привіт, як справи?", partial: "")

        XCTAssertEqual(layer.visibleSpans.count, 1)
        XCTAssertEqual(layer.visibleSpans.first?.id, id)
        XCTAssertEqual(layer.visibleSpans.first?.state, .committed)
        XCTAssertEqual(layer.segmentStableText, "Привіт, як справи?")
    }

    /// Sessions report the *cumulative* committed string; only the increment is a span.
    func testOnlyTheIncrementOfCommittedBecomesANewSpan() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "One.", partial: "")
        layer.ingest(committed: "One. Two.", partial: "")
        layer.ingest(committed: "One. Two. Three.", partial: "thr")

        XCTAssertEqual(layer.visibleSpans.map(\.text), ["One.", "Two.", "Three.", "thr"])
        XCTAssertEqual(layer.visibleSpans.map(\.state),
                       [.committed, .committed, .committed, .provisional])
        XCTAssertEqual(layer.segmentText, "One. Two. Three. thr")
        XCTAssertEqual(layer.segmentStableText, "One. Two. Three.")
    }

    func testClearedPartialIsDroppedAndLeavesNoText() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Committed.", partial: "ghost")
        layer.ingest(committed: "Committed.", partial: "")

        XCTAssertEqual(layer.spans.count, 2)
        XCTAssertEqual(layer.spans.last?.state, .dropped)
        XCTAssertEqual(layer.segmentText, "Committed.")
    }

    /// Apple's chunk rotation can restate what it had already committed. The split was
    /// never promised to anyone, so the segment's committed text collapses into one span.
    func testCommittedTextThatIsNotAnExtensionRewritesTheSegment() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Раз. Два.", partial: "")
        layer.ingest(committed: "Раз, два, три.", partial: "")

        XCTAssertEqual(layer.segmentStableText, "Раз, два, три.")
        XCTAssertEqual(layer.visibleSpans.count, 1)
    }

    /// The batch tier has no live text at all: the whole segment arrives at once.
    func testSegmentResultBecomesTheFirstSpanWhenThereWasNoLiveText() {
        var layer = TranscriptSpanLayer()
        layer.commitSegment("Цілий сегмент з батча.")

        XCTAssertEqual(layer.visibleSpans.map(\.text), ["Цілий сегмент з батча."])
        XCTAssertEqual(layer.visibleSpans.first?.state, .committed)
    }

    /// A stream's `finish()` hands back exactly what it already committed — so nothing is
    /// redrawn, the spans keep their identities, and the ghost text goes.
    func testSegmentResultEqualToTheSpansLeavesThemInPlace() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "One. Two.", partial: "thr")
        let ids = layer.visibleSpans.filter { $0.state.isStable }.map(\.id)

        layer.commitSegment("One. Two.")

        XCTAssertEqual(layer.visibleSpans.map(\.id), ids)
        XCTAssertEqual(layer.segmentText, "One. Two.")
        XCTAssertEqual(layer.segmentProvisionalText, "")
    }

    /// The streaming fallback's shape: the socket committed words and then died, and the
    /// batch upload of the same audio spells them differently. The upload wins.
    func testSegmentResultThatDiffersReplacesTheLiveText() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Раз два", partial: "три")
        layer.commitSegment("Раз, два, три.")

        XCTAssertEqual(layer.segmentText, "Раз, два, три.")
        XCTAssertEqual(layer.segmentStableText, "Раз, два, три.")
    }

    /// An empty result against non-empty spans is not a correction into nothing.
    func testEmptySegmentResultLeavesTheSpansAlone() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Something was said.", partial: "")
        layer.commitSegment("   ")

        XCTAssertEqual(layer.segmentText, "Something was said.")
    }

    func testSettledSpansAreTerminal() {
        var layer = TranscriptSpanLayer()
        layer.commitSegment("Final.")
        layer.settleSegment()
        let id = layer.visibleSpans.first!.id

        XCTAssertEqual(layer.span(id)?.state, .settled)
        XCTAssertFalse(layer.revise(id, text: "Something else."))
        XCTAssertEqual(layer.segmentText, "Final.")
    }

    func testRevisedSpanKeepsItsPlaceInTheOrder() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "One.", partial: "")
        layer.ingest(committed: "One. Two.", partial: "")
        layer.ingest(committed: "One. Two. Three.", partial: "")
        let second = layer.visibleSpans[1].id

        XCTAssertTrue(layer.revise(second, text: "Zwei."))
        XCTAssertEqual(layer.span(second)?.state, .revised)
        XCTAssertEqual(layer.segmentText, "One. Zwei. Three.")
    }

    /// The invariant the whole state machine exists for: what the user typed over stays.
    func testFrozenSpanIsNeverRewritten() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Моя правка.", partial: "")
        let id = layer.visibleSpans.first!.id
        layer.freeze(id)

        XCTAssertFalse(layer.revise(id, text: "Чужа правка."))
        layer.commitSegment("Зовсім інший текст.")
        layer.ingest(committed: "І ще інший.", partial: "")

        XCTAssertEqual(layer.span(id)?.text, "Моя правка.")
        XCTAssertEqual(layer.span(id)?.state, .frozen)
        XCTAssertEqual(layer.segmentText, "Моя правка.")
    }

    /// A segment that holds *both* a frozen span and a rewritable one: the rewrite is
    /// refused outright. Applying it would leave the frozen words standing and spell them
    /// a second time inside the rewritten sibling.
    func testMixedFrozenSegmentRefusesTheRewrite() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Один.", partial: "")
        layer.ingest(committed: "Один. Два.", partial: "")
        let first = layer.visibleSpans[0].id
        let second = layer.visibleSpans[1].id
        layer.freeze(first)

        layer.commitSegment("Один. Два. Три.")

        XCTAssertEqual(layer.span(first)?.text, "Один.")
        XCTAssertEqual(layer.span(first)?.state, .frozen)
        XCTAssertEqual(layer.span(second)?.text, "Два.")
        XCTAssertEqual(layer.segmentText, "Один. Два.")
    }

    /// A pause/resume: `segmentText` (what the engine exposes as `liveText`) starts over,
    /// the recording's text does not.
    func testNewSegmentStartsTheLiveTextOverWithoutLosingTheRecording() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Перший сегмент.", partial: "")
        layer.settleSegment()
        layer.beginSegment()

        XCTAssertEqual(layer.segmentText, "")
        XCTAssertEqual(layer.text, "Перший сегмент.")

        layer.ingest(committed: "Другий сегмент.", partial: "")
        XCTAssertEqual(layer.segmentText, "Другий сегмент.")
        XCTAssertEqual(layer.text, "Перший сегмент. Другий сегмент.")
    }

    /// The words were spoken and the session that would have confirmed them is gone.
    func testClosingASegmentCommitsItsLeftoverPartial() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "", partial: "недоговорене")
        layer.beginSegment()

        XCTAssertEqual(layer.spans.first?.state, .committed)
        XCTAssertEqual(layer.text, "недоговорене")
    }

    /// The second segment's cumulative committed string starts from zero again — it must
    /// not be diffed against the first segment's.
    func testCommittedTrackerResetsWithTheSegment() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Один два три.", partial: "")
        layer.beginSegment()
        layer.ingest(committed: "Чотири.", partial: "")

        XCTAssertEqual(layer.text, "Один два три. Чотири.")
        XCTAssertEqual(layer.visibleSpans.count, 2)
    }

    func testCancelledRecordingDropsEverythingProvisional() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Сіло.", partial: "рухається")
        layer.dropProvisional()

        XCTAssertEqual(layer.segmentText, "Сіло.")
        XCTAssertNil(layer.visibleSpans.first { $0.state == .provisional })
    }

    func testResetClearsTheTimeline() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Щось.", partial: "ще")
        layer.beginSegment()
        layer.reset()

        XCTAssertTrue(layer.spans.isEmpty)
        XCTAssertEqual(layer.text, "")
        XCTAssertEqual(layer.segment, 0)
    }
}

// MARK: - Merging a stream's text (TranscriptMerge.swift)

/// The bug these guard: Scribe re-states what it has already committed — the partials
/// after a commit, and the next commit itself, can carry the whole accumulated
/// transcript with its tail extended and a word or two revised. Appending that pasted
/// the dictation twice, in two slightly different versions.
final class TranscriptMergeTests: XCTestCase {

    private let committed = "Скажи, будь ласка, а цей модуль — парсер, кеш — уже готовий, перевірений? Що там узагалі нового? Це..."
    private let restated = "Скажи, будь ласка, а цей модуль — парсер, кеш — уже готовий, перевірений? Що там узагалі нового? Це нові задачі?"

    func testACommitRestatingEverythingReplacesItRatherThanDoublingIt() {
        XCTAssertEqual(mergedTranscript(committed, restated), restated)
    }

    func testAPartialRestatingEverythingIsReducedToWhatItAdds() {
        XCTAssertEqual(transcriptContinuation(of: committed, in: restated), "нові задачі?")
    }

    func testAnExactEchoAddsNothing() {
        XCTAssertEqual(transcriptContinuation(of: committed, in: committed), "")
        XCTAssertEqual(mergedTranscript(committed, committed), committed)
    }

    func testAGenuineNextSegmentIsAppended() {
        XCTAssertEqual(mergedTranscript("Привіт.", "Як справи?"), "Привіт. Як справи?")
        XCTAssertEqual(transcriptContinuation(of: "Привіт.", in: "Як справи?"), "Як справи?")
    }

    func testEmptySidesAreJoinedAsBefore() {
        XCTAssertEqual(mergedTranscript("", "Привіт"), "Привіт")
        XCTAssertEqual(mergedTranscript("Привіт", ""), "Привіт")
        XCTAssertEqual(transcriptContinuation(of: "", in: "Привіт"), "Привіт")
    }

    /// A restatement is recognised through the revisions the server makes as it gains
    /// context — the whole point is that an exact prefix test misses them.
    func testARestatementSurvivesARevisedWord() {
        let head = "Коли я відкрив свій старий нод"
        let tail = "Коли я відкрив свій старий ноут удома, я бачу ось таке."
        XCTAssertEqual(mergedTranscript(head, tail), tail)
    }

    /// Too different to be a restatement: those are two things the user said.
    func testATextThatMerelyOpensWithTheSameWordIsNotARestatement() {
        let head = "Скажи, будь ласка, про що цей код"
        let tail = "Скажи ще раз, я не почув, і потім продовжимо"
        XCTAssertEqual(mergedTranscript(head, tail), head + " " + tail)
    }

    /// The other shape: the stream re-sends only the tail of what is committed.
    func testARepeatedRunAtTheBoundaryIsDroppedOnce() {
        let head = "Один два три чотири п\u{2019}ять шість"
        let tail = "три чотири п\u{2019}ять шість сім вісім"
        XCTAssertEqual(mergedTranscript(head, tail), "Один два три чотири п\u{2019}ять шість сім вісім")
    }

    /// A short repeat is speech, not a re-send: people do say a word twice.
    func testAShortRepeatIsLeftAlone() {
        XCTAssertEqual(mergedTranscript("Так, так", "так, добре"), "Так, так так, добре")
    }

    // A revision that changes the word count. Position by position, every word after
    // it is shifted and the restatement reads as new speech; by their longest common
    // subsequence the words still agree.

    private let fnCommitted = "Так, треба перевірити шорткати, де їх немає. Можливо, FN+Q, A, W, E."
    private let fnPartial = "Так, треба перевірити шорткати, де їх немає. Можливо, FN плюс Q, A, W."

    /// One word revised into three — the partial Scribe sent right after the commit it
    /// restates. It adds nothing, so nothing is joined onto the commit.
    func testARestatementWhereOneWordSplitsIntoThreeAddsNothing() {
        XCTAssertEqual(transcriptContinuation(of: fnCommitted, in: fnPartial), "")
        XCTAssertEqual(transcriptContinuation(of: fnCommitted, in: fnCommitted.replacingOccurrences(of: "FN+Q", with: "FN плюс Q") + " А потім збережи."),
                       "А потім збережи.")
    }

    /// The same restatement as a commit that went on to say more: it replaces what we
    /// hold, its version of the revised word included.
    func testACommitWhereOneWordSplitsIntoThreeReplacesTheHead() {
        let restated = "Так, треба перевірити шорткати, де їх немає. Можливо, FN плюс Q, A, W, E. А потім збережи."
        XCTAssertEqual(mergedTranscript(fnCommitted, restated), restated)
    }

    /// Three words revised into one. The head is long enough that three changed words
    /// still leave `restatementAgreement` of it in order; a short one stays on the strict
    /// comparison.
    func testARestatementWhereThreeWordsMergeIntoOneIsRecognised() {
        let head = "Так, треба перевірити шорткати, де їх немає. Можливо, FN плюс Q, A, W, E, і тоді перевір, чи працює"
        let tail = "Так, треба перевірити шорткати, де їх немає. Можливо, FN+Q, A, W, E, і тоді перевір, чи працює. Добре."
        XCTAssertEqual(mergedTranscript(head, tail), tail)
        XCTAssertEqual(transcriptContinuation(of: head, in: tail), "Добре.")
    }

    /// A partial that has not caught up with the commit — the issue's own — is an echo,
    /// but merged as a commit it must not cut off the words it has not reached.
    func testARestatementThatStopsShortDoesNotShortenTheHead() {
        XCTAssertEqual(mergedTranscript(fnCommitted, fnPartial), fnCommitted)
    }

    /// A long head that a new sentence merely opens like is still two things said.
    func testAnOpeningAloneDoesNotRestateALongHead() {
        let head = "Я думаю, що це добре, але потім треба буде переписати весь модуль"
        let tail = "Я думаю, що це погано"
        XCTAssertEqual(mergedTranscript(head, tail), head + " " + tail)
    }

    /// In-order words are easy to find: a next sentence reusing a few of them is still
    /// a next sentence.
    func testANextSentenceSharingSomeWordsInOrderIsAppended() {
        let head = "Я думаю, що це добре"
        let tail = "Я не знаю, що ти думаєш про це"
        XCTAssertEqual(mergedTranscript(head, tail), head + " " + tail)
    }
}

// MARK: - Settling the stop's commit (StreamingTranscribers.swift)

final class StreamFinishSettleTests: XCTestCase {

    func testAPartialBeforeAnyCommitReplyIsPassedOn() {
        var settle = StreamFinishSettle()
        XCTAssertFalse(settle.holds(partial: "Друге речення"))
        XCTAssertFalse(settle.isUnresolved)
    }

    func testAPartialAfterACommitReplyIsHeldAndUnresolvedUntilACommitCarriesIt() {
        var settle = StreamFinishSettle()
        settle.committed()
        XCTAssertTrue(settle.holds(partial: "Всі так раптом домовились, що вони..."))
        XCTAssertTrue(settle.isUnresolved)
        settle.committed()
        XCTAssertFalse(settle.isUnresolved)
    }

    func testAnEmptyPartialAfterACommitReplyIsNotHeld() {
        var settle = StreamFinishSettle()
        settle.committed()
        XCTAssertFalse(settle.holds(partial: "  "))
        XCTAssertFalse(settle.isUnresolved)
    }

    /// The race the end of the wait lost: a partial held as the grace ran out. Ending the
    /// wait sees it, so the stream fails and the segment is uploaded rather than pasted
    /// without its last words.
    func testEndingTheWaitWithAPartialHeldIsUnresolved() {
        var settle = StreamFinishSettle()
        settle.committed()
        XCTAssertTrue(settle.holds(partial: "Друге речення"))
        XCTAssertTrue(settle.end())
    }

    func testEndingTheWaitWithNothingHeldIsSettled() {
        var settle = StreamFinishSettle()
        settle.committed()
        XCTAssertFalse(settle.end())
        XCTAssertTrue(settle.isOver)
    }

    /// The other order: the wait ended first. The partial is not passed on — joined onto
    /// the stop's text it would double the dictation — nor held, where nothing would
    /// ever settle it, so ending the wait again still says settled.
    func testAPartialAfterTheWaitEndedIsDroppedNotHeld() {
        var settle = StreamFinishSettle()
        settle.committed()
        XCTAssertFalse(settle.end())
        XCTAssertTrue(settle.holds(partial: "Всі так раптом домовились, що вони..."))
        XCTAssertFalse(settle.isUnresolved)
        XCTAssertFalse(settle.end())
    }

    /// With no commit reply the wait ended on the timeout, and a partial is the final
    /// segment taking shape: it is passed on, as before.
    func testAPartialAfterTheWaitEndedWithNoReplyIsPassedOn() {
        var settle = StreamFinishSettle()
        XCTAssertFalse(settle.end())
        XCTAssertFalse(settle.holds(partial: "Друге речення"))
    }
}

// MARK: - Open segment clock

final class OpenSegmentClockTests: XCTestCase {
    private func bytes(_ seconds: Double) -> Int { Int(seconds * 16_000) * 2 }

    func testItMeasuresTheAudioSentNotTheClock() {
        var clock = OpenSegmentClock(sampleRate: 16_000)
        clock.feed(byteCount: bytes(7.5))
        XCTAssertEqual(clock.longestSeconds, 7.5, accuracy: 0.001)
    }

    func testTheLongestSegmentIsKeptAcrossCommits() {
        var clock = OpenSegmentClock(sampleRate: 16_000)
        clock.feed(byteCount: bytes(18))
        clock.segmentClosed()
        clock.feed(byteCount: bytes(4))
        clock.segmentClosed()
        clock.feed(byteCount: bytes(6))
        XCTAssertEqual(clock.longestSeconds, 18, accuracy: 0.001)
    }

    /// The segment still open counts, so a dictation the server never committed is measured.
    func testTheOpenSegmentCounts() {
        var clock = OpenSegmentClock(sampleRate: 16_000)
        clock.feed(byteCount: bytes(3))
        clock.segmentClosed()
        clock.feed(byteCount: bytes(21))
        XCTAssertEqual(clock.longestSeconds, 21, accuracy: 0.001)
    }

    func testOnlyALongerSegmentExceedsTheLimit() {
        var clock = OpenSegmentClock(sampleRate: 16_000)
        clock.feed(byteCount: bytes(30))
        XCTAssertFalse(clock.exceeded(30))
        clock.feed(byteCount: bytes(0.1))
        XCTAssertTrue(clock.exceeded(30))
        XCTAssertFalse(clock.exceeded(nil), "no limit, no upload")
    }

    /// Scribe's server runs VAD and gets the limit; OpenAI's keeps one item open until the
    /// stop by design, and an upload model has no stream to limit.
    func testOnlyAServerVADStreamIsLimited() {
        func configuration(_ provider: STTProviderType, _ models: [Provider: String]) -> RecordingConfiguration {
            RecordingConfiguration(provider: provider, locale: "uk-UA", localeIsAutomatic: false, apiKeys: [:], models: models)
        }
        XCTAssertEqual(configuration(.elevenlabs, [.elevenLabs: elevenLabsRealtimeModel]).longestTrustedStreamSegment,
                       STTTuning.streamLongestTrustedSegmentSeconds)
        XCTAssertNil(configuration(.openai, [.openAI: openAIRealtimeSTTModel]).longestTrustedStreamSegment)
        XCTAssertNil(configuration(.elevenlabs, [.elevenLabs: "scribe_v2"]).longestTrustedStreamSegment)
    }
}

/// Apple's on-device results, as the e2e harness recorded them, lose no words —
/// neither to a reset after a pause nor to an empty final.
final class AppleUtterancesTests: XCTestCase {
    private func heard(_ results: [String]) -> AppleUtterances {
        var utterances = AppleUtterances()
        for result in results { utterances.receive(result) }
        return utterances
    }

    func testAnEmptyFinalKeepsWhatWasHeard() {
        let utterances = heard(["Вчора", "Вчора Олена Коваленко", "Вчора Олена Коваленко і Тарас Шевчук зус", ""])
        XCTAssertEqual(utterances.text, "Вчора Олена Коваленко і Тарас Шевчук зус")
    }

    func testAResetAfterAPauseKeepsTheSentenceBeforeIt() {
        let utterances = heard([
            "Завтра", "Завтра ми поїдемо", "Завтра ми поїдемо до моря",
            "Якщо", "Якщо погода буде тепло", "Якщо погода буде теплою і сонячною", "",
        ])
        XCTAssertEqual(utterances.settled, "Завтра ми поїдемо до моря")
        XCTAssertEqual(utterances.text, "Завтра ми поїдемо до моря Якщо погода буде теплою і сонячною")
    }

    func testARevisionIsNotANewUtterance() {
        // A word growing, the first word growing into itself, a revised first word in a
        // result as long as the last: all one utterance, so nothing is said twice.
        XCTAssertEqual(heard(["Вчора Олена Кова", "Вчора Олена Коваленко"]).text, "Вчора Олена Коваленко")
        XCTAssertEqual(heard(["За ми", "Завтра"]).text, "Завтра")
        XCTAssertEqual(heard(["Вчора Олена", "Учора Олена"]).text, "Учора Олена")
        XCTAssertEqual(heard(["Так", "Ні"]).text, "Ні")
    }

    /// A sentence after a pause whose first word only begins like the last one's ("I" →
    /// "It", "The" → "Then", "There" → "The") is a new utterance, and the one before it is
    /// kept — a prefix of a short word matched almost anything, and lost the sentence.
    func testAResetWhoseFirstWordBeginsLikeTheLastOnesKeepsTheSentenceBeforeIt() {
        let sentences = [
            ("I went to the store", "It was closed"),
            ("A dog barked at the cat", "And then it ran away"),
            ("The store was closed", "Then we went home"),
            ("There was nobody at home", "The door was locked"),
            ("І ми пішли до парку", "Ідемо далі"),
            ("А ми підемо додому", "Але не сьогодні"),
            ("Я купив хліб і молоко", "Якщо буде час"),
        ]
        for (before, after) in sentences {
            let firstWord = String(after.prefix { !$0.isWhitespace })
            let utterances = heard([before, firstWord, after])
            XCTAssertEqual(utterances.settled, before, after)
            XCTAssertEqual(utterances.text, "\(before) \(after)")
        }
    }

    /// The same audio heard again: a short first word merged with the next into a longer
    /// one spells about as much, so it is a revision, not a sentence said twice.
    func testAShortFirstWordMergedIntoALongerOneIsARevision() {
        XCTAssertEqual(heard(["А ле", "Але"]).text, "Але")
        XCTAssertEqual(heard(["I am going", "I'm going"]).text, "I'm going")
        XCTAssertEqual(heard(["A round the corner", "Around the corner"]).text, "Around the corner")
    }

    /// en-plain's sentences (Audio/en-plain.json) with a pause before each, unpunctuated as
    /// the on-device recogniser writes them: "If" begins like "I", and the second
    /// sentence was lost to it.
    func testEveryEnglishSentenceIsKeptAcrossPauses() {
        let sentences = [
            "Today I am checking how the app recognizes ordinary English speech",
            "I am speaking calmly at a normal pace without long pauses",
            "If everything works this text will appear in the document without a single mistake",
        ]
        var results: [String] = []
        for sentence in sentences {
            let words = sentence.split(separator: " ")
            results += [String(words[0]), words.prefix(4).joined(separator: " "), sentence]
        }
        XCTAssertEqual(heard(results + [""]).text, sentences.joined(separator: " "))
    }

    func testAFinalThatRestatesEverythingIsNotDoubled() {
        let utterances = heard([
            "Завтра ми поїдемо до моря", "Якщо погода",
            "Завтра ми поїдемо до моря. Якщо погода буде теплою",
        ])
        XCTAssertEqual(utterances.settled, "Завтра ми поїдемо до моря")
        XCTAssertEqual(utterances.text, "Завтра ми поїдемо до моря Якщо погода буде теплою")
    }

    /// The session's events through the span layer, as the overlay and the stop read them:
    /// the sentence before the pause is committed once, and the empty final drops nothing.
    func testTheSpanLayerKeepsEveryUtterance() {
        var utterances = AppleUtterances()
        var layer = TranscriptSpanLayer()
        layer.beginSegment()
        for result in ["Завтра ми поїдемо до моря", "Якщо", "Якщо погода буде теплою", ""] {
            utterances.receive(result)
            layer.ingest(committed: utterances.settled, partial: utterances.current)
        }
        XCTAssertEqual(layer.text, "Завтра ми поїдемо до моря Якщо погода буде теплою")
    }

    func testTheSpanLayerKeepsTheSentenceBeforeAResetOnAShortWord() {
        var utterances = AppleUtterances()
        var layer = TranscriptSpanLayer()
        layer.beginSegment()
        for result in ["I went to the store", "It", "It was closed", ""] {
            utterances.receive(result)
            layer.ingest(committed: utterances.settled, partial: utterances.current)
        }
        XCTAssertEqual(layer.text, "I went to the store It was closed")
    }
}

/// A chunk whose task failed after the segment had words is replaced at once, within the
/// bounds that keep a recogniser failing on every task from becoming a loop of new ones —
/// on a fake clock, as the session's `systemUptime` would read.
final class AppleErrorRotationTests: XCTestCase {
    private let limit = AppleErrorRotation.barrenRotationLimit

    func testTheFirstErrorAfterWordsRotatesAtOnce() {
        var rotation = AppleErrorRotation()
        rotation.chunkStarted(at: 100)
        rotation.heardWords()
        XCTAssertEqual(rotation.decide(at: 120, isFeeding: true), .rotate(after: 0))
        XCTAssertEqual(rotation.barrenRotations, 0)
    }

    /// The first chunk is the session's start, not a rotation: it is held to the same
    /// minimum life.
    func testAChunkIsNotReplacedBeforeItHasLivedTheMinimum() {
        var rotation = AppleErrorRotation()
        rotation.chunkStarted(at: 100)
        rotation.heardWords()
        XCTAssertEqual(rotation.decide(at: 100.25, isFeeding: true), .rotate(after: 0.75))

        rotation.chunkStarted(at: 101)
        XCTAssertEqual(rotation.decide(at: 101, isFeeding: true), .rotate(after: 1))

        rotation.chunkStarted(at: 102)
        XCTAssertEqual(rotation.decide(at: 103.5, isFeeding: true), .rotate(after: 0))
    }

    /// However fast the chunks fail, a fresh one starts at most once a minimum, and the
    /// barren ones stop after the limit: a bounded number of tasks, then the 50 s timer.
    func testChunksThatFailAtOnceAreRotatedAtMostOnceAMinimumAndThenLeftToTheTimer() {
        var rotation = AppleErrorRotation()
        var now: TimeInterval = 0
        rotation.chunkStarted(at: now)
        rotation.heardWords()
        now = 30
        XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .rotate(after: 0))
        var started = 0
        for _ in 0..<10 {
            rotation.chunkStarted(at: now)
            now += 0.01
            switch rotation.decide(at: now, isFeeding: true) {
            case .rotate(let delay):
                XCTAssertEqual(delay, AppleErrorRotation.minimumChunkSeconds - 0.01, accuracy: 1e-9)
                now += delay
                started += 1
            case .leaveToTimer, .notFeeding:
                break
            }
        }
        XCTAssertEqual(started, limit)
        XCTAssertEqual(rotation.barrenRotations, limit)
    }

    /// `barrenRotationLimit` rotations in a row whose chunk heard nothing are allowed; the
    /// next such failure is not.
    func testTheStreakBound() {
        var rotation = AppleErrorRotation()
        rotation.chunkStarted(at: 0)
        rotation.heardWords()
        var now: TimeInterval = 10
        XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .rotate(after: 0))
        for barren in 1...limit {
            rotation.chunkStarted(at: now)
            now += 5
            XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .rotate(after: 0), "barren rotation \(barren)")
            XCTAssertEqual(rotation.barrenRotations, barren)
        }
        rotation.chunkStarted(at: now)
        now += 5
        XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .leaveToTimer)

        // The 50 s rotation starts another chunk; one that hears nothing is still left.
        rotation.chunkStarted(at: now + 45)
        XCTAssertEqual(rotation.decide(at: now + 60, isFeeding: true), .leaveToTimer)
        XCTAssertEqual(rotation.barrenRotations, limit)
    }

    /// A chunk that hears words proves the recogniser works: the run is over, whether that
    /// chunk later fails or lasts until the timer.
    func testAChunkThatHeardWordsResetsTheStreak() {
        var rotation = AppleErrorRotation()
        rotation.chunkStarted(at: 0)
        rotation.heardWords()
        var now: TimeInterval = 10
        XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .rotate(after: 0))
        for _ in 1...limit {
            rotation.chunkStarted(at: now)
            now += 5
            _ = rotation.decide(at: now, isFeeding: true)
        }
        rotation.chunkStarted(at: now)
        now += 5
        XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .leaveToTimer)

        // The 50 s timer's chunk hears words, then fails: rotated at once, streak cleared.
        rotation.chunkStarted(at: now + 45)
        rotation.heardWords()
        XCTAssertEqual(rotation.barrenRotations, 0)
        XCTAssertEqual(rotation.decide(at: now + 70, isFeeding: true), .rotate(after: 0))
        XCTAssertEqual(rotation.barrenRotations, 0)

        // And the full allowance of barren rotations is there again.
        now += 70
        for barren in 1...limit {
            rotation.chunkStarted(at: now)
            now += 2
            XCTAssertEqual(rotation.decide(at: now, isFeeding: true), .rotate(after: 0))
            XCTAssertEqual(rotation.barrenRotations, barren)
        }
    }

    func testNothingRotatesWhenTheSessionIsNoLongerFed() {
        var rotation = AppleErrorRotation()
        rotation.chunkStarted(at: 0)
        rotation.heardWords()
        XCTAssertEqual(rotation.decide(at: 10, isFeeding: false), .notFeeding)
        rotation.chunkStarted(at: 10)
        XCTAssertEqual(rotation.decide(at: 20, isFeeding: false), .notFeeding)
        XCTAssertEqual(rotation.barrenRotations, 0, "a pause or a stop counts nothing")
    }

    /// The first words of the chunk an error rotation started are reported once — the
    /// session's proof in the Debug Log that the dictation came back. A timer's chunk, or
    /// a later result, is not.
    func testTheFirstWordsAfterAnErrorRotationAreReportedOnce() {
        var rotation = AppleErrorRotation()
        rotation.chunkStarted(at: 0)
        XCTAssertFalse(rotation.heardWords(), "the session's first chunk")
        XCTAssertEqual(rotation.decide(at: 10, isFeeding: true), .rotate(after: 0))
        rotation.chunkStarted(at: 10)
        XCTAssertTrue(rotation.heardWords())
        XCTAssertFalse(rotation.heardWords())

        rotation.chunkStarted(at: 60)
        XCTAssertFalse(rotation.heardWords(), "a chunk the 50 s timer started")

        // A deferred rotation reports its chunk too, once it starts.
        rotation.chunkStarted(at: 110)
        rotation.heardWords()
        XCTAssertEqual(rotation.decide(at: 110.5, isFeeding: true), .rotate(after: 0.5))
        rotation.chunkStarted(at: 111)
        XCTAssertTrue(rotation.heardWords())
    }
}
