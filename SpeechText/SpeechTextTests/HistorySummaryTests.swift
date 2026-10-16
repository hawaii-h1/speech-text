// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The main window's History: its days, its filters and its search — built from records
/// made here, never the user's own.
final class HistorySummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    /// Wednesday 30 September 2026, 15:00 in Kyiv.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

    private func record(daysAgo: Int = 0, hoursAgo: Int = 0, text: String = "one two three",
                        status: TranscriptionRecord.Status = .success,
                        refinement: TranscriptionRecord.Refinement? = nil, app: String? = nil) -> TranscriptionRecord {
        let date = calendar.date(byAdding: .hour, value: -hoursAgo, to: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)!
        return TranscriptionRecord(id: UUID(), date: date, text: text, status: status,
                                   errorMessage: status == .failed ? "No connection" : nil,
                                   provider: "groq", locale: "uk", duration: 6,
                                   refinement: refinement, destinationApp: app)
    }

    private func refinement(output: String = "Hello there.", preset: String? = "Email / Message",
                            failed: Bool = false, edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: "hello there", outputText: failed ? "" : output, presetName: preset,
                                       provider: "anthropic", model: "claude-sonnet-5",
                                       errorMessage: failed ? "HTTP 529" : nil, editsSelection: edit)
    }

    // MARK: App icons

    func testAnAppIsFoundByTheBundleIDRecordedWithItsName() {
        var older = record(daysAgo: 1, app: "T3 Code (Alpha)")
        older.destinationBundleID = "com.t3tools.t3code.old"
        var newer = record(app: "T3 Code (Alpha)")
        newer.destinationBundleID = "com.t3tools.t3code"
        var started = record(app: "Mail")
        started.originApp = "Notes"
        started.originBundleID = "com.apple.Notes"
        var edit = record(refinement: refinement(edit: true))
        edit.refinement?.context = FocusContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let records = [newer, older, started, edit, record(app: "Pages")]

        XCTAssertEqual(AppIdentity.bundleID(forAppNamed: "T3 Code (Alpha)", in: records), "com.t3tools.t3code")
        XCTAssertEqual(AppIdentity.bundleID(forAppNamed: "Notes", in: records), "com.apple.Notes")
        XCTAssertEqual(AppIdentity.bundleID(forAppNamed: "Slack", in: records), "com.tinyspeck.slackmacgap")
        XCTAssertNil(AppIdentity.bundleID(forAppNamed: "Pages", in: records), "written before bundle IDs were kept")
        XCTAssertNil(AppIdentity.bundleID(forAppNamed: "Mail", in: records))
    }

    func testAnAppThatIsGoneIsDrawnWithAnotherChannelOfIt() {
        XCTAssertEqual(AppIdentity.baseName("T3 Code (Alpha)"), "T3 Code")
        XCTAssertEqual(AppIdentity.baseName("Visual Studio Code"), "Visual Studio Code")
        XCTAssertEqual(AppIdentity.baseName("(Beta)"), "(Beta)")

        let installed = ["Mail", "T3 Code (Nightly)", "T3 Code (Beta)", "Xcode"]
        XCTAssertEqual(AppIdentity.sibling(of: "T3 Code (Alpha)", among: installed), "T3 Code (Beta)")
        XCTAssertEqual(AppIdentity.sibling(of: "T3 Code (Alpha)", among: installed + ["T3 Code"]), "T3 Code",
                       "the plain name before any channel")
        XCTAssertEqual(AppIdentity.sibling(of: "Cursor", among: ["Cursor (Nightly)"]), "Cursor (Nightly)")
        XCTAssertNil(AppIdentity.sibling(of: "T3 Code (Alpha)", among: ["Mail", "T3"]))
        XCTAssertNil(AppIdentity.sibling(of: "Mail", among: ["Mail", "Mailbird"]), "only another channel, never itself")
    }

    // MARK: App and date

    func testHistoryIsNarrowedToAnAppAsItsRowNamesIt() {
        let records = [record(app: "Slack"), record(hoursAgo: 1, app: "Slack"), record(daysAgo: 1, app: "Mail"),
                       record(daysAgo: 2), record(daysAgo: 3, status: .empty)]
        XCTAssertEqual(HistoryNarrowing.apps(in: records).map(\.app), ["Slack", "Mail", "Not pasted", "Record Window"])
        XCTAssertEqual(HistoryNarrowing.apps(in: records).first?.count, 2)
        let slack = HistoryDay.group(records, narrowing: HistoryNarrowing(app: "Slack"), now: now, calendar: calendar)
        XCTAssertEqual(slack.flatMap(\.records).count, 2)
        let unpasted = HistoryDay.group(records, narrowing: HistoryNarrowing(app: "Not pasted"), now: now, calendar: calendar)
        XCTAssertEqual(unpasted.flatMap(\.records).map(\.status), [.empty])
    }

    func testHistoryIsNarrowedToARangeOfDaysOrOneDay() {
        let records = [record(), record(daysAgo: 1), record(daysAgo: 6), record(daysAgo: 7), record(daysAgo: 40)]
        func count(_ dates: HistoryDates) -> Int {
            HistoryDay.group(records, narrowing: HistoryNarrowing(dates: dates), now: now, calendar: calendar)
                .flatMap(\.records).count
        }
        XCTAssertEqual(count(.anyTime), 5)
        XCTAssertEqual(count(.today), 1)
        XCTAssertEqual(count(.last7Days), 3, "today and the six days before it")
        XCTAssertEqual(count(.last30Days), 4)
        XCTAssertEqual(count(.day(calendar.date(byAdding: .day, value: -7, to: now)!)), 1)
    }

    // MARK: How long History keeps dictations

    func testHistoryKeepsASpanOfTimeThisSessionOrEverything() {
        let records = (0..<1200).map { record(hoursAgo: $0 * 12) }
        let launch = calendar.date(byAdding: .hour, value: -30, to: now)!
        func kept(_ retention: HistoryRetention) -> Int {
            retention.keptCount(of: records, now: now, sessionStart: launch, calendar: calendar)
        }
        XCTAssertEqual(kept(.forever), 1200)
        XCTAssertEqual(kept(.days7), 15, "two a day for seven days, and the one right on the line")
        XCTAssertEqual(kept(.days30), 61)
        XCTAssertEqual(kept(.months3), 185, "back to 30 June: 92 days, on the calendar")
        XCTAssertEqual(kept(.months6), 369, "back to 30 March: 184 days")
        XCTAssertEqual(kept(.year), 731)
        XCTAssertEqual(kept(.session), 3, "what this run of the app made: 0, 12 and 24 hours ago")
        XCTAssertEqual(HistoryRetention.session.keptCount(of: records, now: now, sessionStart: .distantFuture,
                                                          calendar: calendar), 0, "nothing past quit")
    }

    func testAnUpdateDeletesNothing() {
        XCTAssertEqual(HistoryRetention.default, .forever)
        XCTAssertEqual(HistoryRetention.stored(nil), .forever)
        XCTAssertEqual(HistoryRetention.stored("300"), .forever, "the count History once kept by")
        XCTAssertEqual(HistoryRetention.stored("1000"), .forever)
        XCTAssertEqual(HistoryRetention.stored("1y"), .year)
        XCTAssertEqual(HistoryRetention.defaultAudio, .days7, "what a failed dictation's audio always got")
        XCTAssertEqual(HistoryRetention.stored(nil, default: .defaultAudio), .days7)
        XCTAssertEqual(HistoryRetention.stored("none", default: .defaultAudio), .session)
    }

    func testAFailedDictationsAudioGoesWithItsRecord() {
        let failed = record()
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .days7, history: .forever, calendar: calendar),
                       "until Wednesday 7 October")
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .forever, history: .days30, calendar: calendar),
                       "until Friday 30 October", "History's shorter span decides")
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .days7, history: .session, calendar: calendar),
                       "until SpeechText quits")
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .forever, history: .forever, calendar: calendar),
                       "for as long as History keeps it")
        XCTAssertEqual(HistoryFormat.storageSummary(count: 125, since: calendar.date(byAdding: .day, value: -16, to: now),
                                                    bytes: 0, calendar: calendar).prefix(35),
                       "125 dictations since 14 September ·")
        XCTAssertEqual(HistoryFormat.storageSummary(count: 0, since: nil, bytes: 0), "No dictations kept yet.")
        XCTAssertEqual(HistoryFormat.retentionSummary(history: .forever, audio: .days7),
                       "History keeps every dictation on this Mac. A failed one's audio is kept for 7 days, for a retry.")
        XCTAssertEqual(HistoryFormat.retentionSummary(history: .days30, audio: .year),
                       "History keeps the last 30 days of dictations on this Mac. A failed one's audio is kept for 30 days, for a retry.")
        XCTAssertEqual(HistoryFormat.retentionSummary(history: .session, audio: .days7),
                       "History keeps this session's dictations, until SpeechText quits. A failed one's audio is kept until SpeechText quits, for a retry.")
    }

    // MARK: Days

    func testRecordsAreGroupedByDayNewestFirst() {
        let records = [record(), record(hoursAgo: 2), record(daysAgo: 1), record(daysAgo: 9)]
        let days = HistoryDay.group(records, calendar: calendar)
        XCTAssertEqual(days.map(\.records.count), [2, 1, 1])
        XCTAssertEqual(days.map { $0.title(now: now, calendar: calendar) }, ["Today", "Yesterday", "21 September"])
    }

    func testADayWithinTheWeekIsNamedAndDatedAndAnOlderYearSaysSo() {
        let monday = HistoryDay.group([record(daysAgo: 2)], calendar: calendar)[0]
        XCTAssertEqual(monday.title(now: now, calendar: calendar), "Monday")
        XCTAssertEqual(monday.subtitle(now: now, calendar: calendar), "28 September")
        let lastYear = HistoryDay.group([record(daysAgo: 400)], calendar: calendar)[0]
        XCTAssertEqual(lastYear.title(now: now, calendar: calendar), "26 August 2025")
        XCTAssertNil(lastYear.subtitle(now: now, calendar: calendar))
    }

    func testADayCountsTheWordsDeliveredNotAnEditsInstruction() {
        let day = HistoryDay.group([
            record(text: "uh hello", refinement: refinement(output: "Hello, Olena — sorry.")),
            record(text: "shorter", refinement: refinement(edit: true)),
            record(status: .failed),
        ], calendar: calendar)[0]
        XCTAssertEqual(day.words, 4)
    }

    // MARK: Filters

    func testEachFilterKeepsItsOwn() {
        let plain = record(), rewritten = record(refinement: refinement()), edit = record(refinement: refinement(edit: true))
        let failed = record(status: .failed), empty = record(status: .empty), fellBack = record(refinement: refinement(failed: true))
        let all = [plain, rewritten, edit, failed, empty, fellBack]
        func ids(_ filter: HistoryFilter) -> [UUID] { all.filter(filter.includes).map(\.id) }
        XCTAssertEqual(ids(.all).count, 6)
        XCTAssertEqual(ids(.rewritten), [rewritten.id, fellBack.id])
        XCTAssertEqual(ids(.edits), [edit.id])
        XCTAssertEqual(ids(.failed), [failed.id, empty.id, fellBack.id], "a rewrite that fell back did not come out as asked")
    }

    // MARK: Search

    func testSearchFindsEveryWordAnywhereIgnoringCaseAndAccents() {
        let rewritten = record(text: "лист Олені", refinement: refinement(output: "Привіт, Олено!"), app: "Mail")
        XCTAssertTrue(HistorySearch.matches(rewritten, query: "олено"), "the rewrite is searched")
        XCTAssertTrue(HistorySearch.matches(rewritten, query: "ЛИСТ mail"), "what was said, and the app")
        XCTAssertTrue(HistorySearch.matches(rewritten, query: "email"), "the prompt's name")
        XCTAssertFalse(HistorySearch.matches(rewritten, query: "лист slack"), "every word has to be found")
        XCTAssertTrue(HistorySearch.matches(record(text: "Café"), query: "cafe"))
        XCTAssertTrue(HistorySearch.matches(record(status: .failed), query: "connection"), "the error is searched")
        XCTAssertTrue(HistorySearch.matches(record(), query: "  "))
    }

    func testGroupingAppliesTheFilterAndTheSearch() {
        let days = HistoryDay.group([record(text: "buy milk"), record(daysAgo: 1, text: "milk", status: .failed),
                                     record(daysAgo: 2, text: "bread")],
                                    filter: .all, query: "milk", calendar: calendar)
        XCTAssertEqual(days.map(\.records.count), [1, 1])
        XCTAssertEqual(HistoryDay.group([record(), record(status: .failed)], filter: .failed, calendar: calendar)
            .flatMap(\.records).count, 1)
    }

    // MARK: Rows

    func testARowSaysARewriteFellBackAndWhereNothingWasPasted() {
        XCTAssertEqual(HomeRecentEntry(record(refinement: refinement(failed: true))).tags, [.rewriteFailed])
        let failedEdit = HomeRecentEntry(record(text: "shorter", refinement: refinement(failed: true, edit: true)))
        XCTAssertEqual(failedEdit.tags, [.edit, .rewriteFailed])
        XCTAssertEqual(failedEdit.text, "hello there", "the selection that was left as it was")
        XCTAssertEqual(HomeRecentEntry(record(status: .failed)).place, "Not pasted")
        XCTAssertEqual(HomeRecentEntry(record()).place, "Record Window")
        XCTAssertEqual(HomeRecentEntry(record(app: "Slack")).place, "Slack")
    }

    func testARowShowsALettersParagraphsOnOneLine() {
        let letter = "Hi Amie!\n\nOkay, thanks for the information.  Yes, I’ve learned Spanish.\n"
        let entry = HomeRecentEntry(record(text: letter))
        XCTAssertEqual(entry.preview, "Hi Amie! Okay, thanks for the information. Yes, I’ve learned Spanish.")
        XCTAssertEqual(entry.text, letter, "Copy keeps the line breaks")
    }

    // MARK: Formatting

    func testTheFactsAreWrittenAsAPersonWould() {
        XCTAssertEqual(HistoryFormat.clock(now, calendar: calendar), "15:00")
        XCTAssertEqual(HistoryFormat.full(now, calendar: calendar), "Wednesday 30 September 2026, 15:00")
        XCTAssertEqual(HistoryFormat.length(8.4), "8 s")
        XCTAssertEqual(HistoryFormat.length(65), "1:05")
        XCTAssertNil(HistoryFormat.length(0))
        XCTAssertEqual(HistoryFormat.engine("local"), "On this Mac")
        XCTAssertEqual(HistoryFormat.engine("elevenlabs"), "ElevenLabs")
        XCTAssertEqual(HistoryFormat.language("uk"), "Ukrainian")
        XCTAssertNil(HistoryFormat.language("auto"))
    }
}
