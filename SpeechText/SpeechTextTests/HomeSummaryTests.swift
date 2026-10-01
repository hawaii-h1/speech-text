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
        XCTAssertEqual(HomeTalk(tick: 0, ai: false, holdToTalk: false).phase, .idle)
        let hearing = HomeTalk(tick: 8 + 4 * 5, ai: false, holdToTalk: false)
        XCTAssertEqual(hearing.phase, .hear)
        XCTAssertEqual(hearing.heard, 6)
        XCTAssertEqual(hearing.partial.split(separator: " ").count, 2, "the last two words are the partial")
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words, ai: false, holdToTalk: false).caption, .words)
        let done = HomeTalk(tick: 8 + 4 * words + 3, ai: false, holdToTalk: false)
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(done.caption, .pasted)
        XCTAssertEqual(done.display, .idle)
        // …and loops.
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words + 3 + 30, ai: false, holdToTalk: false).phase, .idle)
    }

    func testTheAITabRewritesBeforeItPastes() {
        let words = HomeTalk.ai.said.count
        let work = HomeTalk(tick: 8 + 4 * words + 5, ai: true, holdToTalk: false)
        XCTAssertEqual(work.phase, .work)
        XCTAssertEqual(work.caption, .rewriting)
        XCTAssertEqual(work.display, .busy)
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words + 14, ai: true, holdToTalk: false).phase, .done)
    }

    func testTheKeysTapWithoutHoldToTalkAndStayDownWithIt() {
        let words = HomeTalk.dictate.said.count
        let middle = 8 + 2 * words
        XCTAssertTrue(HomeTalk(tick: 8, ai: false, holdToTalk: false).keysDown, "pressed to start")
        XCTAssertFalse(HomeTalk(tick: middle, ai: false, holdToTalk: false).keysDown)
        XCTAssertTrue(HomeTalk(tick: 8 + 4 * words - 1, ai: false, holdToTalk: false).keysDown, "pressed to stop")
        XCTAssertTrue(HomeTalk(tick: middle, ai: false, holdToTalk: true).keysDown)
        XCTAssertFalse(HomeTalk(tick: 8 + 4 * words, ai: false, holdToTalk: true).keysDown, "let go at the stop")
    }
}

private extension TranscriptionRecord {
    func withRefinement(_ refinement: Refinement) -> TranscriptionRecord {
        var copy = self
        copy.refinement = refinement
        return copy
    }
}
