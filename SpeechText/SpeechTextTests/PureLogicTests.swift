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
