// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

// These tests compile the app's source files directly into the test bundle (see the
// SpeechTextTests target's Sources phase) — there is no `@testable import`, because the
// app is an LSUIElement agent that prompts for microphone access at launch, and hosting
// tests inside it would hang a headless run. Everything exercised here must therefore
// be constructible without UserDefaults: the user's real API keys live in the
// com.speechtext.app domain and the tests never read or write it.

// MARK: - Multipart helpers (STTProvider.swift)

final class MultipartTests: XCTestCase {

    func testAppendMultipartFieldLayout() {
        var body = Data()
        body.appendMultipartField(boundary: "BOUND", name: "model", value: "whisper-large-v3-turbo")
        let expected = "--BOUND\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"
        XCTAssertEqual(String(data: body, encoding: .utf8), expected)
    }

    func testAppendMultipartFileLayout() {
        let payload = Data([0x01, 0x02, 0x03])
        var body = Data()
        body.appendMultipartFile(boundary: "BOUND", name: "file",
                                 filename: "recording.flac", mimeType: "audio/flac",
                                 data: payload)
        var expected = "--BOUND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.flac\"\r\nContent-Type: audio/flac\r\n\r\n".data(using: .utf8)!
        expected.append(payload)
        expected.append("\r\n".data(using: .utf8)!)
        XCTAssertEqual(body, expected)
    }

    func testMultipartAudioPartPicksTypeFromExtension() {
        let flac = multipartAudioPart(for: URL(fileURLWithPath: "/tmp/x.flac"))
        XCTAssertEqual(flac.filename, "recording.flac")
        XCTAssertEqual(flac.mimeType, "audio/flac")

        let wav = multipartAudioPart(for: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(wav.filename, "recording.wav")
        XCTAssertEqual(wav.mimeType, "audio/wav")

        // No extension degrades to WAV — the historical container.
        let bare = multipartAudioPart(for: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(bare.mimeType, "audio/wav")
    }
}

// MARK: - RecordingConfiguration derivations

final class RecordingConfigurationTests: XCTestCase {

    /// Constructed directly — never via `current()`, which reads the real defaults.
    private func config(provider: STTProviderType, elevenLabsModel: String = "scribe_v1",
                        groqModel: String = "whisper-large-v3-turbo",
                        localeIsAutomatic: Bool = false) -> RecordingConfiguration {
        RecordingConfiguration(provider: provider, locale: "en-US",
                               localeIsAutomatic: localeIsAutomatic,
                               groqAPIKey: "gk", groqModel: groqModel,
                               elevenLabsAPIKey: "ek", elevenLabsModel: elevenLabsModel)
    }

    func testStreamsOnlyForElevenLabsRealtimeModel() {
        XCTAssertTrue(config(provider: .elevenlabs, elevenLabsModel: elevenLabsRealtimeModel).streams)
        XCTAssertFalse(config(provider: .elevenlabs, elevenLabsModel: "scribe_v1").streams)
        // The model string alone must not be enough: the provider has to match too.
        XCTAssertFalse(config(provider: .groq, elevenLabsModel: elevenLabsRealtimeModel).streams)
        XCTAssertFalse(config(provider: .apple).streams)
    }

    func testBatchModelMapsRealtimeToScribeV1() {
        XCTAssertEqual(config(provider: .elevenlabs, elevenLabsModel: elevenLabsRealtimeModel).batchModel,
                       "scribe_v1")
        XCTAssertEqual(config(provider: .elevenlabs, elevenLabsModel: "scribe_v2").batchModel,
                       "scribe_v2")
    }

    func testBatchModelForAppleAndGroqIsGroqModel() {
        XCTAssertEqual(config(provider: .apple, groqModel: "whisper-large-v3").batchModel,
                       "whisper-large-v3")
        XCTAssertEqual(config(provider: .groq, groqModel: "whisper-large-v3-turbo").batchModel,
                       "whisper-large-v3-turbo")
    }

    func testBatchAPIKeyFollowsProvider() {
        XCTAssertEqual(config(provider: .elevenlabs).batchAPIKey, "ek")
        XCTAssertEqual(config(provider: .groq).batchAPIKey, "gk")
        XCTAssertEqual(config(provider: .apple).batchAPIKey, "gk")
    }

    /// The bug this guards: "Auto" resolved the keyboard layout to a locale and then
    /// *forced* it on the cloud model. Dictating Ukrainian with a US layout sent
    /// `language_code=en`, and Scribe answered with a translated fragment of the
    /// recording instead of what was said.
    func testAutomaticLocaleSendsNoLanguageToACloudModel() {
        XCTAssertNil(config(provider: .elevenlabs, localeIsAutomatic: true).cloudLanguage)
        XCTAssertNil(config(provider: .groq, localeIsAutomatic: true).cloudLanguage)
    }

    func testAChosenLanguageIsStillSent() {
        XCTAssertEqual(config(provider: .elevenlabs).cloudLanguage, "en-US")
    }

    /// Apple's recogniser has no auto mode, so the keyboard-layout guess is all it can
    /// be given — and History records what was actually requested of each tier.
    func testHistoryLocaleRecordsWhatWasRequested() {
        XCTAssertEqual(config(provider: .apple, localeIsAutomatic: true).historyLocale, "en-US")
        XCTAssertEqual(config(provider: .elevenlabs, localeIsAutomatic: true).historyLocale, autoLanguageID)
        XCTAssertEqual(config(provider: .elevenlabs).historyLocale, "en-US")
    }
}

// MARK: - TextRefinementService.parse

final class TextRefinementParseTests: XCTestCase {

    func testModeMarkerIsStrippedAndReported() {
        let result = TextRefinementService.parse("<<mode:Clean-up>>\nHello there.")
        XCTAssertEqual(result.presetName, "Clean-up")
        XCTAssertEqual(result.text, "Hello there.")
    }

    func testMissingMarkerYieldsNilPreset() {
        let result = TextRefinementService.parse("Hello there.")
        XCTAssertNil(result.presetName)
        XCTAssertEqual(result.text, "Hello there.")
    }

    func testEmptyModeNameYieldsNilPreset() {
        let result = TextRefinementService.parse("<<mode:>>Hi")
        XCTAssertNil(result.presetName)
        XCTAssertEqual(result.text, "Hi")
    }

    func testWrappingCodeFenceIsStripped() {
        let result = TextRefinementService.parse("<<mode:Code>>\n```swift\nlet a = 1\nlet b = 2\n```")
        XCTAssertEqual(result.presetName, "Code")
        XCTAssertEqual(result.text, "let a = 1\nlet b = 2")
    }

    func testInnerFenceIsContentAndKept() {
        let raw = "Intro line\n```swift\nlet a = 1\n```\nOutro line"
        XCTAssertEqual(TextRefinementService.parse(raw).text, raw)
    }

    func testFenceContainingAnotherFenceIsNotStripped() {
        // First and last lines are fences, but so is one in the middle — stripping the
        // outer pair would corrupt a reply that merely starts and ends with snippets.
        let raw = "```\nabc\n```\ndef\n```"
        XCTAssertEqual(TextRefinementService.parse(raw).text, raw)
    }
}

// MARK: - Realtime stream echo suppression (StreamingSTTProvider.swift)

final class RealtimeEchoTests: XCTestCase {

    /// The bug this guards: Scribe follows its own `committed_transcript` with one more
    /// `partial_transcript` carrying the same words. Joined onto the committed text it
    /// pastes the dictation twice.
    func testPartialRepeatingTheCommittedSegmentIsAnEcho() {
        XCTAssertTrue(ElevenLabsRealtimeProvider.isEchoOfCommitted(
            partial: "Проаналізуй результати тесту.",
            lastCommitted: "Проаналізуй результати тесту."))
    }

    func testEchoComparisonIgnoresSurroundingWhitespace() {
        XCTAssertTrue(ElevenLabsRealtimeProvider.isEchoOfCommitted(
            partial: "  Hello there. ", lastCommitted: "Hello there."))
    }

    func testAGrowingNextSegmentIsNotAnEcho() {
        // Prefixes of the committed text are how a genuine new segment starts.
        XCTAssertFalse(ElevenLabsRealtimeProvider.isEchoOfCommitted(
            partial: "Проаналізуй", lastCommitted: "Проаналізуй результати тесту."))
        XCTAssertFalse(ElevenLabsRealtimeProvider.isEchoOfCommitted(
            partial: "Проаналізуй результати тесту. І ще", lastCommitted: "Проаналізуй результати тесту."))
    }

    func testEmptyPartialOrNoCommitYetIsNotAnEcho() {
        XCTAssertFalse(ElevenLabsRealtimeProvider.isEchoOfCommitted(partial: "", lastCommitted: ""))
        XCTAssertFalse(ElevenLabsRealtimeProvider.isEchoOfCommitted(partial: "   ", lastCommitted: "Hello."))
        XCTAssertFalse(ElevenLabsRealtimeProvider.isEchoOfCommitted(partial: "Hello.", lastCommitted: ""))
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
}

// MARK: - Insertion ledger (InsertionLedger.swift)

/// The ledger is what lets a later pass find its own text again. Everything here is
/// about the guard: it must find the span where it left it, follow it when the document
/// shifted around it, and refuse — rather than guess — when it cannot be sure.
final class InsertionLedgerTests: XCTestCase {

    private func span(_ id: UInt64) -> TranscriptSpanID { TranscriptSpanID(rawValue: id) }

    /// The recorded range wins outright when the text there still matches — which is
    /// also what makes a repeated word resolvable at all: the search fallback would
    /// refuse this document as ambiguous, and it never has to run.
    func testTheRecordedRangeIsPreferredOverSearchingForTheText() {
        var ledger = InsertionLedger()
        let range = NSRange(location: 0, length: 4)
        ledger.insert(span: span(1), range: range, text: "світ")
        XCTAssertEqual(ledger.resolve(span: span(1), in: "світ і світ"), range)
    }

    /// The user typed above the insertion, so it is no longer where it was recorded —
    /// but it is still there, untouched, and exactly once.
    func testASpanThatMovedIsFoundByItsText() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        let resolved = ledger.resolve(span: span(1), in: "Привіт світ")
        XCTAssertEqual(resolved, NSRange(location: 7, length: 4))
    }

    /// The whole point of the guard: the user edited over it, so nothing may be replaced.
    func testASpanTheUserEditedOverIsNotResolved() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        XCTAssertNil(ledger.resolve(span: span(1), in: "Привіт усім"))
    }

    /// Two identical occurrences make "the last one" a guess, and a guess is not
    /// allowed to rewrite the user's document.
    func testAnAmbiguousSpanIsRefusedRatherThanGuessed() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 99, length: 4), text: "світ")
        XCTAssertNil(ledger.resolve(span: span(1), in: "світ і ще раз світ"))
    }

    func testAnUnknownSpanResolvesToNothing() {
        let ledger = InsertionLedger()
        XCTAssertNil(ledger.resolve(span: span(7), in: "Привіт"))
    }

    /// An insertion before an earlier one pushes it along, so its recorded range keeps
    /// describing where its text actually is.
    func testAnEarlierRecordShiftsWhenTextIsInsertedAboveIt() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        ledger.insert(span: span(2), range: NSRange(location: 0, length: 7), text: "Привіт ")
        XCTAssertEqual(ledger.record(for: span(1))?.range, NSRange(location: 7, length: 4))
    }

    /// A replacement of a different length moves everything after it, and only that.
    func testAReplacementShiftsWhatFollowsButNotWhatPrecedes() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 3), text: "Два")
        ledger.insert(span: span(2), range: NSRange(location: 4, length: 3), text: "три")
        ledger.insert(span: span(3), range: NSRange(location: 8, length: 7), text: "чотири!")
        ledger.replaced(span: span(2), at: NSRange(location: 4, length: 3), with: "тринадцять")
        XCTAssertEqual(ledger.record(for: span(1))?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(ledger.record(for: span(2))?.text, "тринадцять")
        XCTAssertEqual(ledger.record(for: span(3))?.range.location, 15)
    }

    func testDeliveredTextJoinsTheRecordsTheWaySpansJoin() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 6), text: "Привіт")
        ledger.insert(span: span(2), range: NSRange(location: 7, length: 4), text: "світ")
        XCTAssertEqual(ledger.deliveredText, "Привіт світ")
    }

    func testClearingLeavesNothingToResolve() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 6), text: "Привіт")
        ledger.clear()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertNil(ledger.resolve(span: span(1), in: "Привіт"))
    }

    /// Untracked text (an Apple pause hands back its own joined string) still occupies
    /// room in the document, so it must still move the records that follow it.
    func testUntrackedTextStillShiftsTheRecordsAroundIt() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        ledger.insert(span: nil, range: NSRange(location: 0, length: 7), text: "Привіт ")
        XCTAssertEqual(ledger.record(for: span(1))?.range.location, 7)
        XCTAssertEqual(ledger.deliveredText, "світ Привіт ")
    }
}

// MARK: - Delivery tiers (DeliveryTier.swift)

/// The tier decides what a recording is allowed to hand over while the user is still
/// speaking. It is taken once, at the start, from what the Accessibility API proved it
/// can do — and the proof is the read-back, not the return code.
final class DeliveryTierTests: XCTestCase {

    private let correctable = AXTextProbe(valueReadable: true, rangeReadable: true, rangeReadsBack: true)

    func testOurOwnSurfaceIsTierAWithoutProbingAnything() {
        let tier = DeliveryTier.resolve(isMessageDelivery: false, isOwnSurface: true, probe: .unavailable)
        XCTAssertEqual(tier, .a)
    }

    func testAnAppThatReadsAndReselectsItsTextIsTierA() {
        let tier = DeliveryTier.resolve(isMessageDelivery: false, isOwnSurface: false, probe: correctable)
        XCTAssertEqual(tier, .a)
    }

    /// The Chromium shape: the range write is accepted and then reads back as something
    /// else. Trusting the return code alone is what would put VS Code in Tier A.
    func testAnAppWhoseRangeDoesNotReadBackIsTierB() {
        var probe = correctable
        probe.rangeReadsBack = false
        XCTAssertEqual(DeliveryTier.resolve(isMessageDelivery: false, isOwnSurface: false, probe: probe), .b)
    }

    /// The Terminal shape: nothing answers at all.
    func testAnAppThatAnswersNothingIsTierB() {
        XCTAssertEqual(DeliveryTier.resolve(isMessageDelivery: false, isOwnSurface: false, probe: .unavailable), .b)
    }

    func testAnAppThatWillNotGiveUpItsValueIsTierB() {
        var probe = correctable
        probe.valueReadable = false
        XCTAssertEqual(DeliveryTier.resolve(isMessageDelivery: false, isOwnSurface: false, probe: probe), .b)
    }

    /// A send outranks everything, including a perfectly correctable text field: the
    /// confirmation panel may only ever show final text.
    func testAMessageSendIsTierCEvenWhereTheAppIsCorrectable() {
        let tier = DeliveryTier.resolve(isMessageDelivery: true, isOwnSurface: true, probe: correctable)
        XCTAssertEqual(tier, .c)
    }

    func testTierCDeliversNothingDuringRecording() {
        XCTAssertFalse(DeliveryTier.c.deliversDuringRecording(aiMode: false))
        XCTAssertFalse(DeliveryTier.c.deliversDuringRecording(aiMode: true))
    }

    func testPlainDictationDeliversDuringRecordingInBothForeignTiers() {
        XCTAssertTrue(DeliveryTier.a.deliversDuringRecording(aiMode: false))
        XCTAssertTrue(DeliveryTier.b.deliversDuringRecording(aiMode: false))
    }

    /// AI mode rewrites the whole dictation at the stop, so anything issued early would
    /// have to be taken back — which no tier can do yet.
    func testAIModeBuffersInEveryTier() {
        XCTAssertFalse(DeliveryTier.a.deliversDuringRecording(aiMode: true))
        XCTAssertFalse(DeliveryTier.b.deliversDuringRecording(aiMode: true))
    }

    func testOnlyTierAIsWorthAnInsertionLedger() {
        XCTAssertTrue(DeliveryTier.a.recordsRanges)
        XCTAssertFalse(DeliveryTier.b.recordsRanges)
        XCTAssertFalse(DeliveryTier.c.recordsRanges)
    }
}

// MARK: - What the stop still has to deliver (InsertionLedger.remainder)

/// This repo has shipped a doubled dictation twice. Delivering spans while the user is
/// still speaking adds a third way to do it — the stop pasting the whole text again over
/// what the app already has — so the subtraction gets its own tests.
final class UndeliveredRemainderTests: XCTestCase {

    private func ledger(delivered: [String]) -> InsertionLedger {
        var ledger = InsertionLedger()
        var location = 0
        for (index, text) in delivered.enumerated() {
            ledger.insert(span: TranscriptSpanID(rawValue: UInt64(index + 1)),
                          range: NSRange(location: location, length: (text as NSString).length),
                          text: text)
            location += (text as NSString).length + 1
        }
        return ledger
    }

    /// Nothing delivered yet: the stop pastes everything, exactly as it always has.
    func testWithNothingDeliveredTheWholeTextIsStillOwed() {
        let ledger = InsertionLedger()
        XCTAssertEqual(ledger.remainder(of: "Привіт, як справи?"), "Привіт, як справи?")
    }

    /// The ordinary shape: the stream committed the opening while the user spoke, and
    /// the final text is that plus the tail it never committed.
    ///
    /// The subtraction is by word, so punctuation the final text added to a word already
    /// delivered goes with that word and is not pasted on its own — the "?" here stays
    /// missing rather than arriving as a fragment. Same trade the streaming merge makes.
    func testOnlyTheTailTheAppHasNotSeenIsOwed() {
        let ledger = self.ledger(delivered: ["Привіт, як справи"])
        let final = "Привіт, як справи? Давно не бачилися."
        XCTAssertEqual(ledger.remainder(of: final), "Давно не бачилися.")
    }

    /// Several deliveries join the way spans join, so the subtraction sees all of them.
    func testEveryDeliveryCountsTowardsWhatTheAppAlreadyHas() {
        let ledger = self.ledger(delivered: ["Один два три", "чотири п'ять шість"])
        let final = "Один два три чотири п'ять шість сім вісім"
        XCTAssertEqual(ledger.remainder(of: final), "сім вісім")
    }

    /// The whole dictation went out as it was committed. Nothing is owed — and that is
    /// the feature working, not a failure to deliver.
    func testATextFullyDeliveredLeavesNothingOwed() {
        let ledger = self.ledger(delivered: ["Привіт, як справи?"])
        XCTAssertEqual(ledger.remainder(of: "Привіт, як справи?"), "")
    }

    /// A word or two revised by a provider that heard more audio is still the same
    /// dictation, not a new one — the tail is owed, the opening is not re-pasted.
    func testARevisedWordDoesNotMakeTheOpeningOwedAgain() {
        let ledger = self.ledger(delivered: ["Що там узагалі нового? Це"])
        let final = "Що там узагалі нового? Це нові задачі?"
        XCTAssertEqual(ledger.remainder(of: final), "нові задачі?")
    }

    /// The batch fallback re-transcribing a segment the stream had already committed:
    /// the final text disagrees with what the app holds rather than extending it. Nil,
    /// because phase A cannot replace what is already in a foreign document, and pasting
    /// the second wording underneath the first is worse than leaving the first standing.
    func testAFinalTextThatDisagreesIsNotPastedUnderneathWhatIsThere() {
        let ledger = self.ledger(delivered: ["Сьогодні дуже гарна погода"])
        XCTAssertNil(ledger.remainder(of: "Завтра буде дощ і сильний вітер"))
    }

    /// Untracked deliveries (a paste whose landing could not be read) count too — the
    /// question the ledger answers is what the app was given, not what can be corrected.
    func testUntrackedDeliveriesAlsoCountAsDelivered() {
        var ledger = InsertionLedger()
        ledger.insert(span: nil, range: NSRange(location: NSNotFound, length: 0), text: "Один два три")
        XCTAssertEqual(ledger.remainder(of: "Один два три чотири п'ять"), "чотири п'ять")
    }
}

// MARK: - Transcript cleanup (TranscriptCleanup.swift)

final class TranscriptCleanupTests: XCTestCase {

    /// Taken from History: what Scribe realtime returned with `no_verbatim=true` on.
    private let recorded = [
        "Перевірю ще раз, як це працює ввечері. Тому всім пока, е-е-е, бувайте!",
        "Також скажу привіт. Ой, е-е-е, ні, не привіт, а пока.",
        "Ну, коротше, щось це таке. Е-е-е...",
        "Ти не пам’ятаєш, вона казала... Цей магазин чи тооо новий, чи то старий...",
        "Отже. А-а-а, ну, перше питанняяя: чи потрібно мені брати",
        "У мене все готово для звіту та, е-е, відправлення на пошту.",
        "Я нажав на кнопку, і я попав на... отримав доступ до форми",
    ]

    func testHesitationsGoWithTheirOwnPunctuation() {
        XCTAssertEqual(cleanedTranscript("Тому всім пока, е-е-е, бувайте!"), "Тому всім пока, бувайте!")
        XCTAssertEqual(cleanedTranscript("Ой, е-е-е, ні, не привіт"), "Ой, ні, не привіт")
        XCTAssertEqual(cleanedTranscript("щось це таке. Е-е-е..."), "щось це таке.")
        XCTAssertEqual(cleanedTranscript("I mean, uh, it's um fine, hmm."), "I mean, it's fine,")
    }

    func testAFillerThatOpenedASentenceHandsOnItsCapital() {
        XCTAssertEqual(cleanedTranscript("Отже. А-а-а, ну, перше"), "Отже. Ну, перше")
        XCTAssertEqual(cleanedTranscript("Еееем, давай"), "Давай")
    }

    /// Words, not sounds: a single or doubled vowel is a word ("а", "у", Russian "ее"),
    /// and so are the fillers that carry meaning elsewhere ("ну", "типу" — "цього типу").
    func testWordsThatLookLikeHesitationsAreKept() {
        let text = "а у ее ем ну цього типу ООО, 5 мм і 5 mm"
        XCTAssertEqual(cleanedTranscript(text), text)
    }

    func testStretchedLettersCollapseButDoublesStay() {
        XCTAssertEqual(cleanedTranscript("перше питанняяя, чи тооо знання"), "перше питання, чи то знання")
    }

    func testTrailingEllipsisEndsTheSentence() {
        XCTAssertEqual(cleanedTranscript("вона казала... Цей"), "вона казала. Цей")
        XCTAssertEqual(cleanedTranscript("я попав на… отримав"), "я попав на. Отримав")
        XCTAssertEqual(cleanedTranscript("справді?... так"), "справді? Так")
        XCTAssertEqual(cleanedTranscript("діапазон 1...5 і далі ... ось"), "діапазон 1...5 і далі ось")
    }

    func testCleaningIsIdempotent() {
        for text in recorded {
            let once = cleanedTranscript(text)
            XCTAssertEqual(cleanedTranscript(once), once, text)
        }
    }

    /// The anti-duplication property: the engine cleans the *cumulative* committed text on
    /// every event and pastes the increment. If a longer transcript's cleaned form did not
    /// extend the shorter one's at a word boundary, the text already pasted would stop
    /// matching and the stop would deliver nothing.
    func testEveryWordPrefixCleansToAPrefixOfTheWhole() {
        for text in recorded {
            let words = text.split(separator: " ")
            var previous = ""
            for count in 1...words.count {
                let cleaned = cleanedTranscript(words.prefix(count).joined(separator: " "))
                XCTAssertTrue(cleaned == previous || previous.isEmpty || cleaned.hasPrefix(previous + " "),
                              "\"\(previous)\" is not extended by \"\(cleaned)\"")
                previous = cleaned
            }
        }
    }

    /// Out of contract, and pinned so it stays a known limit: committed text grows by whole
    /// segments, so a word is never extended in place. If a provider ever does that, this
    /// is the test that explains why delivery breaks.
    func testGrowthInsideAWordIsNotMonotone() {
        XCTAssertEqual(cleanedTranscript("Ой, е"), "Ой, е")
        XCTAssertEqual(cleanedTranscript("Ой, е-е"), "Ой,")
    }

    func testTheSettingCanTurnItOff() {
        var configuration = RecordingConfiguration(provider: .elevenlabs, locale: "uk-UA", localeIsAutomatic: true,
                                                   groqAPIKey: "", groqModel: "", elevenLabsAPIKey: "",
                                                   elevenLabsModel: "scribe_v2_realtime")
        XCTAssertEqual(configuration.cleaned("Ой, е-е-е, ні"), "Ой, ні")
        configuration.removesDisfluencies = false
        XCTAssertEqual(configuration.cleaned("Ой, е-е-е, ні"), "Ой, е-е-е, ні")
    }
}
