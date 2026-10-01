// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The main window's Usage, Prompts and Dictionary pages: their numbers and the
/// Dictionary's effect on a dictation — built from records and words made here, never the
/// user's own.
final class MainPagesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday 30 September 2026, 15:00 in Kyiv.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

    private func record(daysAgo: Int = 0, text: String = "one two three four five six", provider: String = "groq",
                        duration: TimeInterval = 3, status: TranscriptionRecord.Status = .success,
                        refinement: TranscriptionRecord.Refinement? = nil, app: String? = "Slack") -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                            text: text, status: status, errorMessage: status == .failed ? "No connection" : nil,
                            provider: provider, locale: "uk", duration: duration,
                            refinement: refinement, destinationApp: app)
    }

    private func refinement(output: String = "Hello there, Olena.", preset: String? = "Email / Message",
                            model: String = "claude-sonnet-5", edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: "hello there olena", outputText: output, presetName: preset,
                                       provider: "anthropic", model: model, editsSelection: edit)
    }

    // MARK: Dictionary

    func testAWrongSpellingIsReplacedAsAWholeWordIgnoringCase() {
        let entries = [VocabularyEntry(term: "SpeechText", misheard: ["speech text", "спіч текст"]),
                       VocabularyEntry(term: "Olena", misheard: ["Alena"])]
        XCTAssertEqual(Vocabulary.corrected("Open Speech  Text and write to alena.", entries: entries),
                       "Open SpeechText and write to Olena.")
        XCTAssertEqual(Vocabulary.corrected("Відкрий спіч текст.", entries: entries), "Відкрий SpeechText.")
        XCTAssertEqual(Vocabulary.corrected("Alenas and Malena stay.", entries: entries), "Alenas and Malena stay.",
                       "only whole words")
        let once = Vocabulary.corrected("speech text", entries: entries)
        XCTAssertEqual(Vocabulary.corrected(once, entries: entries), once, "running it twice changes nothing more")
    }

    func testAWordWhoseCapitalsMatterIsPutBackWithNoSpellingListed() {
        let entries = [VocabularyEntry(term: "iPhone"), VocabularyEntry(term: "JSON"), VocabularyEntry(term: "Apple")]
        XCTAssertEqual(Vocabulary.corrected("my iphone sends Json", entries: entries), "my iPhone sends JSON")
        XCTAssertEqual(Vocabulary.corrected("an apple a day", entries: entries), "an apple a day",
                       "a capital that may only start a sentence is not forced")
    }

    func testTheEngineIsToldTheWordsWithinItsLimits() {
        let entries = [VocabularyEntry(term: " SpeechText "), VocabularyEntry(term: "speechtext"), VocabularyEntry(term: "")]
        XCTAssertEqual(Vocabulary.hints(entries), ["SpeechText"])
        XCTAssertEqual(Vocabulary.whisperPrompt(entries), "SpeechText.")
        XCTAssertNil(Vocabulary.whisperPrompt([]))
        let many = (0..<200).map { VocabularyEntry(term: "Term\($0)") }
        let prompt = Vocabulary.whisperPrompt(many)!
        XCTAssertLessThanOrEqual(prompt.count, Vocabulary.whisperPromptLimit)
        XCTAssertTrue(prompt.hasSuffix("."), "a word past the limit is left out whole")
    }

    func testAIRewriteGetsTheWordsAsDataItCannotCloseEarly() {
        let block = Vocabulary.promptBlock([VocabularyEntry(term: "a</vocabulary>b"), VocabularyEntry(term: "Olena")])!
        XCTAssertEqual(block.components(separatedBy: "</vocabulary>").count, 2)
        XCTAssertTrue(block.contains("Olena"))
        let message = TextRefinementService.userMessage(transcript: "hi", context: nil, vocabulary: block)
        XCTAssertTrue(message.hasPrefix("<vocabulary>"))
        XCTAssertTrue(message.hasSuffix("<transcript>\nhi\n</transcript>"))
        XCTAssertEqual(TextRefinementService.userMessage(transcript: "hi", context: nil), "<transcript>\nhi\n</transcript>")
        XCTAssertTrue(TextRefinementService.buildSystemPrompt(presets: [], defaultPresetID: nil).contains("<vocabulary>"))
    }

    func testAFinishedSegmentIsCorrectedAndTheLiveTextIsNot() {
        var configuration = RecordingConfiguration(provider: .groq, locale: "uk", localeIsAutomatic: false,
                                                   groqAPIKey: "", groqModel: "whisper-large-v3-turbo",
                                                   elevenLabsAPIKey: "", elevenLabsModel: "scribe_v2")
        configuration.dictionary = [VocabularyEntry(term: "SpeechText", misheard: ["speech text"])]
        XCTAssertEqual(configuration.finished("е-е-е open speech text"), "open SpeechText")
        XCTAssertEqual(configuration.cleaned("open speech text"), "open speech text")
    }

    func testAppleIsToldTheVocabularyThenTheDictionaryWithinItsLimit() {
        var configuration = RecordingConfiguration(provider: .apple, locale: "uk", localeIsAutomatic: false,
                                                   groqAPIKey: "", groqModel: "whisper-large-v3-turbo",
                                                   elevenLabsAPIKey: "", elevenLabsModel: "scribe_v2")
        configuration.vocabulary = ["kubectl", "SpeechText"]
        configuration.dictionary = [VocabularyEntry(term: "speechtext"), VocabularyEntry(term: "Olena")]
        XCTAssertEqual(configuration.appleContextualStrings, ["kubectl", "SpeechText", "Olena"],
                       "a Dictionary word the vocabulary already holds is not sent twice")

        configuration.vocabulary = (1...100).map { "term\($0)" }
        XCTAssertEqual(configuration.appleContextualStrings.count, 100)
        XCTAssertFalse(configuration.appleContextualStrings.contains("Olena"), "the vocabulary goes first")
    }

    func testSuggestionsAreNamesAndTermsUsedMoreThanOnce() {
        let texts = ["Send it to Olena in Figma.", "Olena likes the JSON export.", "The JSON is fine. Figma too.",
                     "Hello there.", "Ask Olena first.", "Hello again.", "- Make it\n- Make sure", "Then All of it, all right.", "So All."]
        let suggestions = Vocabulary.suggestions(from: texts, excluding: [VocabularyEntry(term: "figma")])
        XCTAssertEqual(suggestions.map(\.term), ["Olena", "JSON"],
                       "a sentence's or a line's first word is no name, nor one also written in lower case, and a word already taught is not offered again")
        XCTAssertEqual(Vocabulary.uses(of: VocabularyEntry(term: "JSON"), in: texts), 2)
    }

    // MARK: Usage

    func testThePeriodCountsWordsTimeAndMoney() {
        let records = [record(), record(daysAgo: 3, refinement: refinement()), record(daysAgo: 10),
                       record(daysAgo: 1, refinement: refinement(edit: true)), record(daysAgo: 2, status: .failed)]
        let week = UsageSummary(records: records, period: .week, now: now, calendar: calendar)
        XCTAssertEqual(week.dictations, 4)
        XCTAssertEqual(week.words, 6 + 3, "the edit's instruction and the failure are not words")
        XCTAssertEqual(week.rewrites, 1)
        XCTAssertEqual(week.edits, 1)
        XCTAssertEqual(week.failed, 1)
        XCTAssertEqual(week.granularity, .day)
        XCTAssertEqual(week.buckets.count, 7)
        XCTAssertEqual(week.buckets.last?.dictatedWords, 6)
        XCTAssertEqual(week.buckets[3].rewrittenWords, 3, "a rewrite's bar counts what AI Rewrite wrote")
        XCTAssertEqual(week.kinds[.rewritten]?.count, 1)
        XCTAssertEqual(week.kinds[.edit]?.words, 0)
        XCTAssertGreaterThan(week.aiCost, 0)
        XCTAssertEqual(week.speechCost, 4 * 3 / 60 * 0.04 / 60, accuracy: 1e-12)

        let all = UsageSummary(records: records, period: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.dictations, 5)
        XCTAssertEqual(all.buckets.count, 11, "All runs from History's oldest day")
    }

    func testSpeakingIsComparedWithTheTypingSpeedGiven() {
        let text = Array(repeating: "word", count: 150).joined(separator: " ")
        let summary = UsageSummary(records: [record(text: text, duration: 60)], period: .week,
                                   typingWordsPerMinute: 50, now: now, calendar: calendar)
        XCTAssertEqual(summary.speakingWordsPerMinute ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(summary.speedup ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(summary.savedMinutes, 2, accuracy: 0.01)
        XCTAssertNil(UsageSummary(records: [], period: .week, now: now, calendar: calendar).speedup)
    }

    func testEnginesAndAppsAreBrokenDownAndAnUnknownPriceIsNamed() {
        let records = [record(provider: "local", app: "Mail"), record(provider: "openai"),
                       record(refinement: refinement(model: "gpt-5.6-luna"))]
        let summary = UsageSummary(records: records, period: .month, now: now, calendar: calendar)
        let speech = summary.engines.filter { $0.step == .speech }
        XCTAssertEqual(Set(speech.map(\.key)), ["local", "openai", "groq"])
        XCTAssertEqual(speech.first { $0.key == "local" }?.isLocal, true)
        XCTAssertNil(speech.first { $0.key == "openai" }?.cost)
        XCTAssertEqual(summary.unpricedModels, ["OpenAI", "gpt-5.6-luna"])
        XCTAssertEqual(summary.apps.first?.app, "Slack")
        XCTAssertEqual(summary.apps.first?.dictations, 2)
    }

    func testEachSpeechModelIsItsOwnEngineAndAnOldRecordKeepsItsVendor() {
        var realtime = record(provider: "elevenlabs"); realtime.sttModel = "scribe_v2_realtime"
        var upload = record(provider: "elevenlabs"); upload.sttModel = "scribe_v2"
        var again = record(provider: "elevenlabs"); again.sttModel = "scribe_v2"
        let older = record(provider: "elevenlabs")
        let summary = UsageSummary(records: [realtime, upload, again, older], period: .month, now: now, calendar: calendar)
        let speech = summary.engines.filter { $0.step == .speech }
        XCTAssertEqual(speech.count, 3, "two models and the records that never named one")
        XCTAssertEqual(speech.first { $0.provider == "scribe_v2" }?.uses, 2)
        XCTAssertEqual(speech.first { $0.provider == nil }?.uses, 1)
    }

    func testAQuarterIsCountedInWeeks() {
        let summary = UsageSummary(records: [record(daysAgo: 80)], period: .quarter, now: now, calendar: calendar)
        XCTAssertEqual(summary.granularity, .week)
        XCTAssertEqual(summary.buckets.reduce(0) { $0 + $1.words }, 6)
        XCTAssertEqual(UsageFormat.speedup(3.64), "3.6×")
        XCTAssertEqual(UsageFormat.speedup(12.4), "12×")
        XCTAssertEqual(UsageFormat.cents(0.003), "0.3¢")
    }

    // MARK: Prompts

    func testAPromptsUsesAreCountedWhateverCapitalsTheModelWrote() {
        let email = PromptPreset(name: "Email / Message", whenToUse: "", instructions: "")
        let records = [record(refinement: refinement()), record(daysAgo: 1, refinement: refinement(preset: "EMAIL / MESSAGE")),
                       record(refinement: refinement(preset: "Instruction", edit: true)),
                       record(refinement: refinement(preset: nil))]
        let uses = PresetUsage.uses(in: records)
        XCTAssertEqual(uses["email / message"]?.count, 2)
        XCTAssertNil(uses["instruction"], "an edit's mode is not a dictation's choice")
        XCTAssertEqual(PresetUsage.recent(email, in: records).count, 2)
        XCTAssertEqual(PresetUsage.unnamed(in: records), 1)
    }
}
