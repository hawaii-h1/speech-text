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
        var turbo = record(duration: 60, provider: "groq")
        turbo.sttModel = "whisper-large-v3-turbo"
        var minimax = record(duration: 60, provider: "local",
                             refinement: refinement(model: "minimaxai/minimax-m2.7", provider: "groq"))
        minimax.sttModel = "parakeet-tdt-0.6b-v3"
        let week = HomeWeek(records: [
            turbo,
            minimax,
            record(duration: 60, provider: "groq"),
            record(duration: 60, provider: "openai", refinement: refinement(model: "gpt-9", provider: "openai")),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.speechCost, 0.04 / 60, accuracy: 1e-9)
        XCTAssertEqual(week.aiCost, 0)
        XCTAssertEqual(week.unpricedModels, ["MiniMax M2.7", "Groq", "OpenAI", "gpt-9"],
                       "named as the pages name them: a model with no list price, an engine whose models differ "
                       + "and the record named none, an ID the catalogue does not list")
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
        XCTAssertEqual(HomeFormat.estimate(1.2), "≈ $1.20")
        XCTAssertEqual(HomeFormat.estimate(0), "$0", "nothing spent is exact")
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
        XCTAssertEqual(HomeTalk(tick: 0, mode: .dictate, holdToTalk: false).caption, .hidden,
                       "no glass before the first word — the overlay says no Listening…")
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
        XCTAssertEqual(work.caption, .words, "the words stay while AI works; the comet says it is busy")
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
        XCTAssertEqual(work.caption, .words)
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

/// The list prices on the catalogues: every model has one or says it has none, and the
/// table is written out here, so a refreshed price is a deliberate two-line change
/// (docs/prices.md).
final class ListPriceTests: XCTestCase {
    /// Dollars a minute, and the keyterm surcharge a minute.
    private let speech: [String: (Double, Double)] = [
        "groq/whisper-large-v3-turbo": (0.04 / 60, 0),
        "groq/whisper-large-v3": (0.111 / 60, 0),
        "elevenLabs/scribe_v2": (0.22 / 60, 0.05 / 60),
        "elevenLabs/scribe_v2_realtime": (0.39 / 60, 0.08 / 60),
        "openAI/gpt-transcribe": (0.0045, 0),
        "openAI/gpt-4o-mini-transcribe": (0.003, 0),
        "openAI/gpt-live-transcribe": (0.017, 0),
    ]

    /// Dollars per million tokens: input, cached input, output; nil for not priced.
    private let chat: [String: (Double, Double, Double)?] = [
        "groq/openai/gpt-oss-120b": (0.15, 0.075, 0.60),
        "groq/openai/gpt-oss-20b": (0.075, 0.0375, 0.30),
        "groq/qwen/qwen3.8-27b": (0.80, 0.80, 4.00),
        "groq/minimaxai/minimax-m2.7": nil,
        "anthropic/claude-sonnet-5": (2, 0.20, 10),
        "anthropic/claude-opus-5": (5, 0.50, 25),
        "anthropic/claude-haiku-4-5": (1, 0.10, 5),
        "openai/gpt-5.6-luna": (0.20, 0.02, 1.20),
        "openai/gpt-5.6-terra": (2, 0.20, 12),
        "openai/gpt-5.6-sol": (4, 0.40, 20),
    ]

    func testEverySpeechModelIsPricedFreeOrSaysItIsNot() {
        for model in sttModelCatalog {
            let key = "\(model.vendor.rawValue)/\(model.id)"
            switch model.vendor {
            case .apple, .local:
                XCTAssertEqual(model.price, .free, "\(key) runs on the Mac")
            default:
                guard let expected = speech[key] else { return XCTFail("\(key) has no row here: add its price") }
                guard case .listed(let rates) = model.price else { return XCTFail("\(key) is not priced") }
                XCTAssertEqual(rates.perMinute, expected.0, accuracy: 1e-12, key)
                XCTAssertEqual(rates.keytermSurchargePerMinute, expected.1, accuracy: 1e-12, key)
            }
        }
        let cloud = sttModelCatalog.filter { ![.apple, .local].contains($0.vendor) }
        XCTAssertEqual(Set(cloud.map { "\($0.vendor.rawValue)/\($0.id)" }), Set(speech.keys), "a row for a model that is gone")
    }

    func testEveryChatModelIsPricedFreeOrSaysItIsNot() {
        for model in chatModelCatalog {
            let key = "\(model.provider.rawValue)/\(model.id)"
            if model.provider == .local {
                XCTAssertEqual(model.price, .free, "\(key) runs on the Mac")
                continue
            }
            guard let row = chat[key] else { XCTFail("\(key) has no row here: add its price"); continue }
            guard let expected = row else {
                XCTAssertEqual(model.price, .notPriced, "\(key) is written down as not priced")
                continue
            }
            guard case .listed(let rates) = model.price else { XCTFail("\(key) is not priced"); continue }
            XCTAssertEqual(rates.inputPerToken * 1e6, expected.0, accuracy: 1e-9, key)
            XCTAssertEqual(rates.cachedInputPerToken * 1e6, expected.1, accuracy: 1e-9, key)
            XCTAssertEqual(rates.outputPerToken * 1e6, expected.2, accuracy: 1e-9, key)
            XCTAssertLessThanOrEqual(rates.cachedInputPerToken, rates.inputPerToken, key)
        }
        let cloud = chatModelCatalog.filter { $0.provider != .local }
        XCTAssertEqual(Set(cloud.map { "\($0.provider.rawValue)/\($0.id)" }), Set(chat.keys), "a row for a model that is gone")
    }

    /// An ID the catalogue does not list is never charged at another model's rate.
    func testAnUnlistedModelIsNotPricedUnlessItRunsOnTheMac() {
        XCTAssertEqual(UsagePrices.speech(vendor: .groq, model: "whisper-next"), .notPriced)
        XCTAssertEqual(UsagePrices.speech(vendor: .local, model: "some-local-model"), .free)
        XCTAssertEqual(UsagePrices.chat(provider: "anthropic", model: "claude-next"), .notPriced)
        XCTAssertEqual(UsagePrices.chat(provider: "ollama", model: "llama9:1b"), .free)
        XCTAssertEqual(UsagePrices.chat(vendor: .ollama, model: "gemma4:12b"), .free)
        XCTAssertEqual(UsagePrices.chat(provider: "local", model: "gemma-4-12b-it-qat-q4_0"), .free)
        XCTAssertEqual(UsagePrices.chat(vendor: .local, model: "some-local-model"), .free)
        XCTAssertEqual(UsagePrices.chat(provider: "not-a-provider", model: "x"), .notPriced)
        XCTAssertEqual(UsagePrices.speech(provider: "not-an-engine", model: nil), .notPriced)
        XCTAssertEqual(UsagePrices.speech(provider: "apple", model: nil), .free)
    }

    func testTheTableSaysWhenItWasChecked() {
        XCTAssertEqual(UsagePrices.checkedText, "14 October 2026")
        XCTAssertEqual(UsagePrices.disclaimer, "estimated from known prices")
    }
}
