// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

// The cases of docs/manual-testing.md that are about text rather than about macOS —
// what lands in the document, once, where — replayed through `DictationReplay`. Each test
// is named after its checklist row. The row still exists for what a replay cannot show:
// whether the real app answers the Accessibility API the way `FakeApp` was told to.

// MARK: - Tiers (T)

@MainActor
final class TierReplayTests: XCTestCase {

    override func tearDown() {
        TranscriptJoin.isWord = { _ in false }
        super.tearDown()
    }

    /// Two sentences with a pause between them, as Scribe sends them — including the
    /// partial that re-states a segment it has just committed.
    private let twoSentences: [DictationReplay.Step] = [
        .partial("Привіт"),
        .partial("Привіт, це перше речення"),
        .committed("Привіт, це перше речення."),
        .partial("Привіт, це перше речення."),
        .partial("А це"),
        .committed("А це друге."),
    ]

    /// T1: pasted in pieces while speaking, nothing pasted a second time at the stop.
    func testT1_TextEditGetsEachSentenceOnce() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), twoSentences)

        XCTAssertEqual(run.document, "Привіт, це перше речення. А це друге.")
        XCTAssertTrue(run.logged("tier A (correctable)"))
        XCTAssertTrue(run.logged("finalize: extend"))
        XCTAssertTrue(run.logged("0 left to paste"))
        XCTAssertEqual(run.stop, .nothingLeft)
        XCTAssertNil(run.correctionApplied)
    }

    /// T2: a terminal gets the same pieces, and nothing is ever rewritten.
    func testT2_TerminalGetsCommittedPiecesOnly() async {
        let run = await DictationReplay.run(in: FakeApp(.terminal), twoSentences)

        XCTAssertEqual(run.document, "Привіт, це перше речення. А це друге.")
        XCTAssertTrue(run.logged("tier B (append-only)"))
        XCTAssertTrue(run.logged("landing unknown"))
        XCTAssertEqual(run.stop, .nothingLeft)
    }

    /// T3: Chromium's range write does not read back, so a browser is Tier B.
    func testT3_BrowserIsAppendOnly() async {
        let run = await DictationReplay.run(in: FakeApp(.chromium), twoSentences)

        XCTAssertEqual(run.document, "Привіт, це перше речення. А це друге.")
        XCTAssertTrue(run.logged("tier B (append-only)"))
    }

    /// A partial is never pasted, in any tier: the words still moving at the stop arrive
    /// with the stop.
    func testPartialsAreNeverPasted() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(in: app, [
            .committed("Перше."),
            .partial("Друге ще"),
        ], atStop: [.committed("Друге ще не закінчене.")])

        XCTAssertEqual(run.document, "Перше. Друге ще не закінчене.")
    }

    /// T5: switched to another app mid-dictation and back. Nothing goes into the other
    /// app, and the words said while away still reach the document.
    func testT5_SwitchingAwayAndBackLosesNothing() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(in: app, [
            .committed("Перше речення."),
            .switchAway,
            .committed("Друге, поки я деінде."),
            .switchBack,
            .committed("Третє вже тут."),
        ])

        XCTAssertEqual(app.elsewhere, "")
        XCTAssertTrue(run.logged("not delivering now — the target app is not in front; the stop will"))
        XCTAssertEqual(run.document, "Перше речення. Друге, поки я деінде. Третє вже тут.")
    }

    /// T5 in a terminal, where the stop cannot put the missing sentence back in the middle.
    func testT5_SwitchingAwayAndBackInATerminalLosesNothing() async {
        let app = FakeApp(.terminal)
        let run = await DictationReplay.run(in: app, [
            .committed("Перше речення."),
            .switchAway,
            .committed("Друге, поки я деінде."),
            .switchBack,
            .committed("Третє вже тут."),
        ])

        XCTAssertEqual(app.elsewhere, "")
        XCTAssertEqual(run.document, "Перше речення. Друге, поки я деінде. Третє вже тут.")
    }

    /// T5, never coming back before the stop: what was said while away goes in at the
    /// stop, after what was pasted before.
    func testT5_WordsSaidWhileAwayArriveAtTheStop() async {
        let app = FakeApp(.terminal)
        let run = await DictationReplay.run(in: app, [
            .committed("Перше речення."),
            .switchAway,
            .committed("Друге, поки я деінде."),
            .committed("І третє."),
        ])

        XCTAssertEqual(app.elsewhere, "")
        XCTAssertEqual(run.document, "Перше речення. Друге, поки я деінде. І третє.")
    }

    /// T7: a cancel keeps what was pasted and pastes nothing more.
    func testT7_CancelKeepsWhatWasPastedAndAddsNothing() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), [
            .committed("Перше."),
            .committed("Друге."),
        ], atStop: [.committed("Третє.")], cancelInsteadOfStopping: true)

        XCTAssertEqual(run.document, "Перше. Друге.")
        XCTAssertNil(run.stop)
    }

    /// A cancel while a paste is still landing releases anyone waiting for it: the stop's
    /// wait must not outlive the recording it belonged to.
    func testT7_ACancelReleasesAWaitForAPasteInFlight() {
        let app = FakeApp(.textEdit)
        app.holdsLandings = true
        let delivery = InlineDelivery()
        XCTAssertTrue(delivery.begin(tier: .a, aiMode: false, aiDraft: false, target: app, targetName: nil))
        delivery.enqueue([TranscriptSpan(id: TranscriptSpanID(rawValue: 1), segment: 1, text: "Перше.", state: .committed)])
        XCTAssertTrue(delivery.isDeliveringSpan)

        var released = false
        delivery.whenIdle { released = true }
        XCTAssertFalse(released)
        delivery.end()
        XCTAssertTrue(released)
    }

    /// T10: words committed only by the stop are separated from the text before them
    /// ("Поїха. Ііі…", not "Поїха.Ііі…").
    func testT10_TheStopsTailKeepsItsSpace() async {
        let run = await DictationReplay.run(in: FakeApp(.terminal), [
            .committed("Ну що, поїха."),
            .partial("Ііі далі"),
        ], atStop: [.committed("Ііі далі йдемо.")])

        XCTAssertEqual(run.document, "Ну що, поїха. Ііі далі йдемо.")
        XCTAssertTrue(run.logged("left to paste"))
    }

    /// T11: a second dictation straight after the first, with nothing typed between.
    func testT11_ASecondDictationIsSeparatedFromTheFirst() async {
        let app = FakeApp(.textEdit)
        _ = await DictationReplay.run(in: app, [.committed("Треба це виправити.")])
        _ = await DictationReplay.run(in: app, [.committed("Роблю це зараз.")])

        XCTExpectFailure("Known: the first paste of a dictation never opens with a space, because the app does not read what is before the caret — manual-testing.md T11") {
            XCTAssertEqual(app.document, "Треба це виправити. Роблю це зараз.")
        }
    }

    /// T12: Scribe closed a segment inside a word ("база дани" | "х, звідки").
    func testT12_AWordCutByTheStreamIsGluedBack() async {
        TranscriptJoin.isWord = { ["даних", "база", "звідки"].contains($0.lowercased()) }
        let run = await DictationReplay.run(in: FakeApp(.textEdit), [
            .committed("Ось нова база дани"),
            .committed("х, звідки ми читаємо."),
        ])

        XCTAssertEqual(run.document, "Ось нова база даних, звідки ми читаємо.")
        XCTAssertTrue(run.logged("(joins previous)"))
    }

    /// The doubled dictation: Scribe re-states everything it has committed, grown by a
    /// word or two, as the next partial and then as the next commit.
    func testARestatedTranscriptIsNotPastedTwice() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), [
            .committed("Що там узагалі нового?"),
            .partial("Що там узагалі нового? Це"),
            .committed("Що там узагалі нового? Це нові задачі?"),
        ])

        XCTAssertEqual(run.document, "Що там узагалі нового? Це нові задачі?")
    }

    /// Hesitations are cleaned before they become spans, so the stop's text still
    /// extends what was pasted.
    func testHesitationsNeverReachTheDocument() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), [
            .committed("Я думаю, е-е-е, що так."),
            .committed("Мммм, ну добре."),
        ])

        XCTAssertFalse(run.document.contains("е-е-е"))
        XCTAssertTrue(run.logged("finalize: extend"))
    }

    /// A paste still landing when the stop's result is handled: the stop must not paste
    /// the same words again.
    func testAPasteStillLandingAtTheStopIsNotPastedAgain() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), [
            .committed("Перше речення."),
            .holdLandings,
            .committed("Друге речення."),
        ])

        XCTAssertEqual(run.document, "Перше речення. Друге речення.")
    }
}

// MARK: - Live transcript on the overlay (L)

/// A streaming recording shows its text on the overlay and pastes it once at the stop —
/// `InlineDelivery.begin(livePreview:)`. What these pin down is the reason it exists: a
/// sentence Scribe closed on a pause and reopened a moment later reaches the document in
/// its final form, in every tier.
@MainActor
final class LiveTranscriptReplayTests: XCTestCase {

    /// A pause mid-sentence: Scribe commits it with a full stop, then re-states it with a
    /// comma once the user carries on.
    private let pauseMidSentence: [DictationReplay.Step] = [
        .partial("Я думаю, що ми зробимо"),
        .committed("Я думаю, що ми зробимо."),
        .partial("Я думаю, що ми зробимо, потім"),
        .committed("Я думаю, що ми зробимо, потім перевіримо."),
    ]
    private let live = DictationReplay.Setup(livePreview: true)

    /// L1: a terminal — which can never take back a pasted full stop — gets the
    /// re-punctuated sentence, in one paste.
    func testL1_TheCorrectedSentenceIsPastedOnceInATerminal() async {
        let app = FakeApp(.terminal)
        let run = await DictationReplay.run(live, in: app, pauseMidSentence)

        XCTAssertEqual(run.document, "Я думаю, що ми зробимо, потім перевіримо.")
        XCTAssertEqual(app.pastes.count, 1)
        XCTAssertTrue(run.logged("shown on the overlay, pasted at the stop"))
    }

    /// L2: the same in TextEdit, where nothing is left for the finalizing pass to correct.
    func testL2_NothingGoesOutWhileSpeakingInTextEdit() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(live, in: app, pauseMidSentence)

        XCTAssertEqual(run.document, "Я думаю, що ми зробимо, потім перевіримо.")
        XCTAssertEqual(app.pastes.count, 1)
        XCTAssertNil(run.correctionApplied)
    }

    /// L3: the AI draft setting does not bring early pastes back — the rewrite is the
    /// only thing pasted.
    func testL3_AIDraftIsNotPastedWithALiveTranscript() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true, aiDraft: true, livePreview: true),
                                            in: app, pauseMidSentence, llm: .rewrites("Зробимо, потім перевіримо."))

        XCTAssertEqual(run.document, "Зробимо, потім перевіримо.")
        XCTAssertEqual(app.pastes.count, 1)
    }
}

// MARK: - The finalizing pass (F)

@MainActor
final class FinalizeReplayTests: XCTestCase {

    /// What was pasted before the Wi-Fi dropped, and the batch upload's version of the
    /// whole recording — first word revised, one more sentence after (12:22, 17.09).
    private let beforeTheDrop: [DictationReplay.Step] = [
        .committed("Зроблю це ввечері, коли повернусь додому."),
        .streamBreaks,
    ]
    private let batchVersion = "Роблю це ввечері, коли повернусь додому. І ще одне речення."

    /// F1: one replacement, in place, no second copy.
    func testF1_TextEditIsCorrectedInOneWrite() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), beforeTheDrop,
                                            fallback: ScriptedSegment(text: batchVersion))

        XCTAssertEqual(run.document, batchVersion)
        XCTAssertEqual(run.correctionApplied, true)
        XCTAssertTrue(run.logged("falling back to batch upload"))
        XCTAssertTrue(run.logged("finalize: replace"))
        XCTAssertEqual(run.stop, .nothingLeft)
    }

    /// F2 + F6: a terminal is never corrected, and the sentence said after the drop still
    /// arrives.
    func testF2_TerminalIsLeftAloneAndTheTailStillArrives() async {
        let run = await DictationReplay.run(in: FakeApp(.terminal), beforeTheDrop,
                                            fallback: ScriptedSegment(text: batchVersion))

        XCTAssertEqual(run.document, "Зроблю це ввечері, коли повернусь додому. І ще одне речення.")
        XCTAssertEqual(run.correctionApplied, false)
        XCTAssertTrue(run.logged("finalize: leave"))
    }

    /// F3: a word typed inside the pasted text is the user's, and it stays.
    func testF3_AHandEditIsNotOverwritten() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(in: app, beforeTheDrop + [
            .userTypes("обов'язково ", after: "Зроблю це "),
            .caretToEnd,
        ], fallback: ScriptedSegment(text: batchVersion))

        XCTAssertTrue(run.document.hasPrefix("Зроблю це обов'язково завтра"))
        XCTAssertEqual(run.correctionApplied, false)
        XCTAssertTrue(run.logged("correction refused: the delivered text is not all there, untouched, in one place"))
    }

    /// F4: focus moved to another app — nothing is pasted there, and nothing is corrected.
    func testF4_FocusMovedMeansNoCorrection() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(in: app, [
            .committed("Зроблю це ввечері, коли повернусь додому."),
            .switchAway,
            .committed("А ще подзвоню."),
            .streamBreaks,
        ], fallback: ScriptedSegment(text: "Роблю це ввечері, коли повернусь додому. А ще подзвоню."))

        XCTAssertEqual(app.elsewhere, "")
        XCTAssertTrue(run.logged("not delivering now — the target app is not in front; the stop will"))
        XCTAssertTrue(run.logged("the app or the focused field changed since the recording started — not correcting"))
        XCTAssertEqual(run.correctionApplied, false)
        XCTAssertEqual(run.document, "Зроблю це ввечері, коли повернусь додому. А ще подзвоню.")
    }

    /// F5: another document of the same app. Recorded as it behaves today: the check
    /// while speaking is by app, so later pieces follow the focus into the second
    /// document, and the stop does not correct either one.
    func testF5_AnotherDocumentOfTheSameApp() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(in: app, [
            .committed("Перше речення."),
            .focus("second"),
            .committed("Друге речення."),
        ])

        XCTAssertEqual(app.document, "Перше речення.")
        XCTAssertEqual(app.fields["second"]?.text, " Друге речення.")
        XCTAssertNil(run.correctionApplied)
    }

    /// T5 + F1: away for a sentence, back, then the stream broke and the batch upload
    /// re-worded the start. The words said while away were never pasted, so the one
    /// replacement has to bring them in too — once.
    func testF1_ACorrectionAfterSwitchingAwayPutsEverythingInOnce() async {
        let app = FakeApp(.textEdit)
        let run = await DictationReplay.run(in: app, [
            .committed("Зроблю це ввечері, коли повернусь додому."),
            .switchAway,
            .committed("Подзвоню з дороги."),
            .switchBack,
            .committed("І ще одне речення."),
            .streamBreaks,
        ], fallback: ScriptedSegment(text: "Роблю це ввечері, коли повернусь додому. Подзвоню з дороги. І ще одне речення."))

        XCTAssertEqual(app.elsewhere, "")
        XCTAssertEqual(run.document, "Роблю це ввечері, коли повернусь додому. Подзвоню з дороги. І ще одне речення.")
        XCTAssertEqual(run.correctionApplied, true)
    }

    /// F6 in Tier A with a correction refused: the landing could not be read and the app
    /// refuses the selection, yet the sentence said after the drop still arrives.
    func testF6_TheTailArrivesWhenTheCorrectionIsRefused() async {
        let run = await DictationReplay.run(in: FakeApp(.electronThatLies), beforeTheDrop,
                                            fallback: ScriptedSegment(text: batchVersion))

        XCTAssertEqual(run.document, "Зроблю це ввечері, коли повернусь додому. І ще одне речення.")
        XCTAssertEqual(run.correctionApplied, false)
    }

    /// F6 when the re-wording is too different to find the seam: nothing more is pasted,
    /// and the user is told rather than left with two versions.
    func testF6_ATextTooDifferentIsNotPastedUnderTheFirst() async {
        let run = await DictationReplay.run(in: FakeApp(.terminal), beforeTheDrop,
                                            fallback: ScriptedSegment(text: "Завтра вранці в офісі все зроблю. І ще одне речення."))

        XCTAssertEqual(run.document, "Зроблю це ввечері, коли повернусь додому.")
        XCTAssertEqual(run.stop, .notPasted)
    }

    /// A stream that broke and a batch upload that failed too: the document keeps what
    /// was pasted, and the failure is surfaced.
    func testBothHalvesFailing() async {
        let run = await DictationReplay.run(in: FakeApp(.textEdit), beforeTheDrop,
                                            fallback: ScriptedSegment(error: "offline"))

        XCTAssertEqual(run.document, "Зроблю це ввечері, коли повернусь додому.")
        if case .failed = run.stop {} else { XCTFail("expected .failed, got \(String(describing: run.stop))") }
    }
}

// MARK: - AI mode (A)

@MainActor
final class AIReplayTests: XCTestCase {

    private let dictation: [DictationReplay.Step] = [
        .committed("ну короче напиши що я буду за пів години"),
    ]
    private let rewrite = "Буду за пів години."

    /// A1: no draft — nothing while speaking, one paste of the rewrite.
    func testA1_WithoutADraftOnlyTheRewriteIsPasted() async {
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true), in: FakeApp(.textEdit),
                                            dictation, llm: .rewrites(rewrite))

        XCTAssertEqual(run.document, rewrite)
        XCTAssertTrue(run.logged("buffering until the stop"))
    }

    /// A2: the draft is replaced by the rewrite, in one write.
    func testA2_TheDraftIsReplacedInTextEdit() async {
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true, aiDraft: true),
                                            in: FakeApp(.textEdit), dictation, llm: .rewrites(rewrite))

        XCTAssertEqual(run.document, rewrite)
        XCTAssertTrue(run.logged("AI draft: replace"))
        XCTAssertEqual(run.correctionApplied, true)
    }

    /// A3: no draft in a terminal, where it could not be taken back.
    func testA3_NoDraftInATerminal() async {
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true, aiDraft: true),
                                            in: FakeApp(.terminal), dictation, llm: .rewrites(rewrite))

        XCTAssertEqual(run.document, rewrite)
        XCTAssertTrue(run.logged("tier B (append-only)"))
        XCTAssertTrue(run.logged("buffering until the stop"))
    }

    /// A5: an Electron app that refuses the replacement ends up with both — the user's
    /// choice: the rewrite matters more than the draft staying out of the way.
    func testA5_ARefusedReplacementPastesTheRewriteAfterTheDraft() async {
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true, aiDraft: true),
                                            in: FakeApp(.electronThatLies), dictation, llm: .rewrites(rewrite))

        XCTAssertEqual(run.document, "ну короче напиши що я буду за пів години \(rewrite)")
        XCTAssertTrue(run.logged("AI draft could not be replaced — pasting the AI result as well"))
        XCTAssertEqual(run.correctionApplied, false)
    }

    /// A6: a hand edit in the draft is kept; the rewrite goes after it, separated.
    func testA6_AnEditedDraftIsKept() async {
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true, aiDraft: true),
                                            in: FakeApp(.textEdit),
                                            dictation + [.userTypes("!", after: "короче"), .caretToEnd],
                                            llm: .rewrites(rewrite))

        XCTAssertEqual(run.document, "ну короче! напиши що я буду за пів години \(rewrite)")
        XCTAssertTrue(run.logged("correction refused"))
    }

    /// A7: the LLM failed — the draft stays and no second copy of it is pasted.
    func testA7_AFailedRewriteLeavesTheDraftOnce() async {
        let run = await DictationReplay.run(DictationReplay.Setup(aiMode: true, aiDraft: true),
                                            in: FakeApp(.textEdit), dictation, llm: .fails)

        XCTAssertEqual(run.document, "ну короче напиши що я буду за пів години")
        XCTAssertTrue(run.logged("AI draft: extend"))
    }
}

// MARK: - Recorded traces

/// Every trace in `SpeechTextTests/Traces/`, recorded by the app with Debug Log › Record
/// traces on and copied here by `scripts/import-trace.sh`. Each one must still paste what
/// the app pasted when it was recorded — or, once someone has reviewed it and written
/// `expectedDocument`, leave the document holding exactly that.
@MainActor
final class RecordedTraceTests: XCTestCase {

    private static var tracesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Traces")
    }

    func testEveryRecordedTraceStillReplaysAsRecorded() async throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.tracesDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let traces = files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        try XCTSkipIf(traces.isEmpty, "no recorded traces in \(Self.tracesDirectory.path)")

        for file in traces {
            let trace = try DictationTrace.decode(Data(contentsOf: file))
            let run = await DictationReplay.run(trace)
            let name = file.lastPathComponent
            if let expected = trace.expectedDocument {
                XCTAssertEqual(run.document, expected, "\(name): the document")
            } else {
                XCTAssertEqual(run.app.pastes, DictationReplay.recordedPastes(trace),
                               "\(name): the pastes differ from the recording — if the change is intended, review the trace and set expectedDocument")
            }
        }
    }

    /// The recorder's output reads back, and replays into the pastes it recorded.
    func testATraceRoundTripsAndReplays() async throws {
        let recorder = DictationTraceRecorder(setup: DictationTrace.Setup(
            app: "TextEdit", probe: .init(valueReadable: true, rangeReadable: true, rangeReadsBack: true)))
        recorder.record(.partial, text: "Зроблю це")
        recorder.record(.committed, text: "Зроблю це ввечері, коли повернусь додому.")
        recorder.record(.paste, text: "Зроблю це ввечері, коли повернусь додому.", landing: .exact)
        recorder.record(.committed, text: "Подзвоню з дороги.")
        recorder.record(.targetNotInFront)
        recorder.record(.stop)
        recorder.record(.committed, text: "І ще одне речення.")
        recorder.record(.stopPaste, text: " Подзвоню з дороги. І ще одне речення.")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(recorder.write(into: directory))
        let trace = try DictationTrace.decode(Data(contentsOf: url))
        XCTAssertEqual(trace.events.map(\.kind),
                       [.partial, .committed, .paste, .committed, .targetNotInFront, .stop, .committed, .stopPaste])

        let run = await DictationReplay.run(trace)
        XCTAssertEqual(run.app.pastes, DictationReplay.recordedPastes(trace))
        XCTAssertEqual(run.document, "Зроблю це ввечері, коли повернусь додому. Подзвоню з дороги. І ще одне речення.")
    }

    /// Apple and plain batch dictations have no events to replay, and are not written.
    func testANonStreamedDictationIsNotWritten() {
        let recorder = DictationTraceRecorder(setup: DictationTrace.Setup())
        recorder.record(.stop)
        recorder.record(.stopPaste, text: "Привіт.")
        XCTAssertNil(recorder.write(into: FileManager.default.temporaryDirectory))
    }
}
