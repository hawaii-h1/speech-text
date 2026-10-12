// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The main window's Home: the week it counts from History, the Recent rows, and the
/// intro card's approved animation — built from records made here, never the user's own.
final class HomeSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    /// Wednesday 30 September 2026, 15:00 in Kyiv.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

    private func record(daysAgo: Int = 0, text: String = "one two three four", duration: TimeInterval = 6,
                        status: TranscriptionRecord.Status = .success, provider: String = "groq",
                        refinement: TranscriptionRecord.Refinement? = nil, app: String? = nil) -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                            text: text, status: status, errorMessage: status == .failed ? "Offline" : nil,
                            provider: provider, locale: "uk", duration: duration,
                            refinement: refinement, destinationApp: app)
    }

    private func refinement(input: String = "hello there", output: String = "Hello there.",
                            model: String = "claude-sonnet-5", provider: String = "anthropic",
                            preset: String? = "Email / Message", edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: input, outputText: output, presetName: preset,
                                       provider: provider, model: model, editsSelection: edit)
    }

    // MARK: The week

    func testTheWeekCountsTheLastSevenDaysOnly() {
        let week = HomeWeek(records: [record(), record(daysAgo: 6), record(daysAgo: 7)], now: now, calendar: calendar)
        XCTAssertEqual(week.dictations, 2)
        XCTAssertEqual(week.words, 8)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.isToday, true)
        XCTAssertEqual(week.days.first?.words, 4, "six days ago is the week's first day")
    }

    func testAnEditsInstructionAndAFailureAreNotWords() {
        let week = HomeWeek(records: [
            record(text: "make it shorter", refinement: refinement(edit: true)),
            record(status: .failed),
            record(text: "a b c"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.dictations, 3)
        XCTAssertEqual(week.words, 3)
    }

    func testTheWordsCountedAreTheOnesDelivered() {
        let week = HomeWeek(records: [record(text: "uh email olena", refinement: refinement(output: "Hi Olena, sorry I'm late."))],
                            now: now, calendar: calendar)
        XCTAssertEqual(week.words, 5)
    }

    func testTimeSavedIsTypingTheWordsLessSayingThem() {
        // 80 words: two minutes at 40 wpm, said in half a minute.
        let text = Array(repeating: "word", count: 80).joined(separator: " ")
        let week = HomeWeek(records: [record(text: text, duration: 30)], now: now, calendar: calendar)
        XCTAssertEqual(week.savedMinutes, 1.5, accuracy: 0.0001)
        XCTAssertEqual(week.speakingMinutes, 0.5, accuracy: 0.0001)
    }

    func testSpentPricesWhatItKnowsAndNamesWhatItDoesNot() {
        let week = HomeWeek(records: [
            record(duration: 60, provider: "groq"),
            record(duration: 60, provider: "local"),
            record(duration: 60, provider: "openai", refinement: refinement(model: "gpt-5.6-luna", provider: "openai")),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.speechCost, 0.04 / 60, accuracy: 1e-9)
        XCTAssertEqual(week.aiCost, 0)
        XCTAssertEqual(week.unpricedModels, ["openai", "gpt-5.6-luna"])
    }

    /// Every engine has a price or an explicit "not priced", keyed by the raw value History
    /// stores; a string that names no engine is not priced.
    func testEverySpeechEngineIsPricedOrSaysItIsNot() {
        let expected: [String: Double?] = [
            "apple": 0, "local": 0, "groq": 0.04 / 60, "elevenlabs": 0.40 / 60, "openai": nil,
        ]
        XCTAssertEqual(Set(STTProviderType.allCases.map(\.rawValue)), Set(expected.keys))
        for (provider, price) in expected {
            XCTAssertEqual(UsagePrices.speech(provider: provider), price, provider)
        }
        XCTAssertNil(UsagePrices.speech(provider: "not-an-engine"))
    }

    func testAnOllamaRewriteCostsNothing() {
        let week = HomeWeek(records: [record(provider: "apple", refinement: refinement(model: "gemma4:12b", provider: "ollama"))],
                            now: now, calendar: calendar)
        XCTAssertEqual(week.spent, 0)
        XCTAssertTrue(week.unpricedModels.isEmpty)
    }

    func testADayIsOnlyAsTallAsItsWords() {
        let week = HomeWeek(records: [
            record(text: Array(repeating: "w", count: 120).joined(separator: " ")),
            record(daysAgo: 1, text: "w"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.litRows(for: week.days[6], rows: 12), 12)
        XCTAssertEqual(week.litRows(for: week.days[5], rows: 12), 1, "a day with any words lights at least one row")
        XCTAssertEqual(week.litRows(for: week.days[0], rows: 12), 0)
    }

    func testDurationsAndMoney() {
        XCTAssertEqual(HomeFormat.durationText(minutes: 52.4), "52 min")
        XCTAssertEqual(HomeFormat.durationText(minutes: 65), "1 h 5 min")
        XCTAssertEqual(HomeFormat.durationText(minutes: 120), "2 h")
        XCTAssertEqual(HomeFormat.money(0), "$0")
        XCTAssertEqual(HomeFormat.money(0.004), "<$0.01")
        XCTAssertEqual(HomeFormat.money(0.2), "$0.20")
        XCTAssertEqual(HomeFormat.integer(2831), "2,831")
    }

    // MARK: Recent

    func testARecentRowSaysWhereItWentAndWhatRewroteIt() {
        let entry = HomeRecentEntry(record(app: "Slack").withRefinement(refinement()))
        XCTAssertEqual(entry.text, "Hello there.")
        XCTAssertEqual(entry.app, "Slack")
        XCTAssertEqual(entry.tags, [.preset("Email / Message")])
        XCTAssertEqual(entry.timeText(now: now, calendar: calendar), "15:00")
    }

    func testAnEditIsMarkedAsOneAndAFailureSaysWhy() {
        XCTAssertEqual(HomeRecentEntry(record(refinement: refinement(edit: true))).tags, [.edit])
        let failed = HomeRecentEntry(record(status: .failed))
        XCTAssertEqual(failed.text, "Offline")
        XCTAssertEqual(failed.tags, [.failed])
    }

    // MARK: The intro card's picture

    func testThePictureHearsThenPastesOnce() {
        let words = HomeTalk.dictate.said.count
        XCTAssertEqual(HomeTalk(tick: 0, mode: .dictate, holdToTalk: false).phase, .idle)
        let hearing = HomeTalk(tick: 8 + 4 * 5, mode: .dictate, holdToTalk: false)
        XCTAssertEqual(hearing.phase, .hear)
        XCTAssertEqual(hearing.heard, 6)
        XCTAssertEqual(hearing.partial.split(separator: " ").count, 2, "the last two words are the partial")
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words, mode: .dictate, holdToTalk: false).caption, .words)
        let done = HomeTalk(tick: 8 + 4 * words + 3, mode: .dictate, holdToTalk: false)
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(done.caption, .pasted)
        XCTAssertEqual(done.display, .idle)
        // …and loops.
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words + 3 + 30, mode: .dictate, holdToTalk: false).phase, .idle)
    }

    func testTheAITabRewritesBeforeItPastes() {
        let words = HomeTalk.ai.said.count
        let work = HomeTalk(tick: 8 + 4 * words + 5, mode: .ai, holdToTalk: false)
        XCTAssertEqual(work.phase, .work)
        XCTAssertEqual(work.caption, .rewriting)
        XCTAssertEqual(work.display, .busy)
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words + 14, mode: .ai, holdToTalk: false).phase, .done)
    }

    func testTheKeysGoDownOneAfterAnotherAndTapWithoutHoldToTalk() {
        let words = HomeTalk.dictate.said.count
        let middle = 8 + 2 * words
        func lit(_ tick: Int, hold: Bool = false) -> Set<Int> {
            HomeTalk(tick: tick, mode: .dictate, holdToTalk: hold).litKeys
        }
        XCTAssertEqual(lit(5), [])
        XCTAssertEqual(lit(6), [0], "⌃ first")
        XCTAssertEqual(lit(7), [0, 1], "then ⇧")
        XCTAssertEqual(lit(8), [0, 1, 2], "the letter last, as the overlay starts listening")
        XCTAssertEqual(lit(middle), [])
        XCTAssertEqual(lit(8 + 4 * words - 3), [0], "pressed again to stop, key by key")
        XCTAssertEqual(lit(8 + 4 * words - 1), [0, 1, 2])
        XCTAssertEqual(lit(8 + 4 * words), [])
    }

    func testWithHoldToTalkOnlyTheLetterStaysDown() {
        let words = HomeTalk.dictate.said.count
        func lit(_ tick: Int) -> Set<Int> { HomeTalk(tick: tick, mode: .dictate, holdToTalk: true).litKeys }
        XCTAssertEqual(lit(8), [0, 1, 2])
        XCTAssertEqual(lit(11), [0, 1, 2])
        XCTAssertEqual(lit(12), [2], "⌃⇧ let go, the letter held")
        XCTAssertEqual(lit(8 + 2 * words), [2])
        XCTAssertEqual(lit(8 + 4 * words), [], "let go at the stop")
        XCTAssertEqual(HomeTalk(tick: 9, mode: .dictate, holdToTalk: true, keyCount: 4).litKeys, [0, 1, 2, 3])
        XCTAssertEqual(HomeTalk(tick: 13, mode: .dictate, holdToTalk: true, keyCount: 4).litKeys, [3])
    }

    func testTheEditTabReplacesTheSelectionAndNeverPastesTheInstruction() {
        let words = HomeTalk.edit.said.count
        let hearing = HomeTalk(tick: 8 + 4, mode: .edit, holdToTalk: false)
        XCTAssertTrue(hearing.isAI && hearing.isEdit)
        XCTAssertEqual(hearing.message, .selection(HomeTalk.edit.selection!), "the selection stays while the instruction is spoken")
        let work = HomeTalk(tick: 8 + 4 * words + 5, mode: .edit, holdToTalk: false)
        XCTAssertEqual(work.caption, .rewriting)
        XCTAssertEqual(work.message, .caret, "cut once the instruction is over")
        let done = HomeTalk(tick: 8 + 4 * words + 14, mode: .edit, holdToTalk: false)
        XCTAssertEqual(done.message, .pasted)
        XCTAssertFalse(HomeTalk.edit.output.contains(HomeTalk.edit.said.joined(separator: " ")))
    }
}

private extension TranscriptionRecord {
    func withRefinement(_ refinement: Refinement) -> TranscriptionRecord {
        var copy = self
        copy.refinement = refinement
        return copy
    }
}
