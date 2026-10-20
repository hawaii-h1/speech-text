// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

// MARK: - Custom vocabulary (CustomVocabulary.swift)

final class CustomVocabularyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func term(_ text: String, daysAgo: Double) -> VocabularyEntry {
        VocabularyEntry(term: text, added: now.addingTimeInterval(-daysAgo * 86_400))
    }

    // MARK: The list an earlier release shipped

    func testTheSpeechPageListMovesIntoTheDictionaryOnce() {
        let existing = [VocabularyEntry(term: "SpeechText", misheard: ["speech text"])]
        let legacy = [VocabularyTerm(text: " speechtext "), VocabularyTerm(text: "kubectl"),
                      VocabularyTerm(text: "  "), VocabularyTerm(text: "Kubectl")]
        let merged = CustomVocabulary.migrateLegacyTerms(legacy, into: existing)
        // A word already there keeps its spellings; a duplicate in any case is not added twice.
        XCTAssertEqual(merged.map(\.term), ["SpeechText", "kubectl"])
        XCTAssertEqual(merged[0].misheard, ["speech text"])
        XCTAssertEqual(merged[1].id, legacy[1].id)
        XCTAssertEqual(merged[1].added, legacy[1].added)
    }

    func testBlankAndRepeatedWordsAreNotSent() {
        let entries = [term(" SpeechText ", daysAgo: 1), term("speechtext", daysAgo: 2), term("", daysAgo: 3)]
        XCTAssertEqual(CustomVocabulary.ranked(entries, now: now, rankByUse: false, historyTexts: { [] }),
                       ["SpeechText"])
    }

    // MARK: Ranking

    func testTermsAddedThisWeekGoFirstNewestFirst() {
        let terms = [term("Old", daysAgo: 30), term("Newer", daysAgo: 1), term("Newest", daysAgo: 0.1)]
        let ranked = CustomVocabulary.ranked(terms, now: now, rankByUse: true,
                                             historyTexts: { ["Old old old"] })
        XCTAssertEqual(ranked, ["Newest", "Newer", "Old"])
    }

    func testOlderTermsAreRankedByWholeWordUseInHistory() {
        let terms = [term("API", daysAgo: 20), term("Kubernetes", daysAgo: 30), term("AC-42", daysAgo: 40)]
        let history = ["A rapid rapid change", "kubernetes, and Kubernetes again", "ac-42 shipped"]
        let ranked = CustomVocabulary.ranked(terms, now: now, rankByUse: true, historyTexts: { history })
        // "rapid" is not "API"; case and punctuation are ignored.
        XCTAssertEqual(ranked, ["Kubernetes", "AC-42", "API"])
    }

    func testHistoryIsNotReadWhenNoModelNeedsTheRanking() {
        let terms = [term("B", daysAgo: 30), term("A", daysAgo: 20)]
        let ranked = CustomVocabulary.ranked(terms, now: now, rankByUse: false,
                                             historyTexts: { XCTFail("History read"); return [] })
        XCTAssertEqual(ranked, ["A", "B"])
    }

    // MARK: Fitting a list to a model

    func testAModelGetsWhatItAcceptsUpToItsCountAndNothingIsCut() {
        let ranked = ["Short", "A name longer than twenty", "Two", "Three"]
        let limits = TermListLimits(maxTerms: 2, maxCharacters: 20, maxWords: 5, forbidden: [])
        XCTAssertEqual(CustomVocabulary.selected(ranked, limits: limits), ["Short", "Two"])
        XCTAssertEqual(CustomVocabulary.selected(ranked, limits: nil), [])
    }

    func testAForbiddenCharacterSkipsTheTermNotTheRequest() {
        // Stored JSON may come from anywhere — an older domain, a hand edit.
        let ranked = ["ok", "a<b", "line\nbreak", "{x}"]
        XCTAssertEqual(CustomVocabulary.selected(ranked, limits: .openAIKeywords), ["ok", "{x}"])
        XCTAssertEqual(CustomVocabulary.selected(ranked, limits: .scribeUpload), ["ok"])
    }

    func testTheCataloguesLimits() {
        let hundred = (0..<150).map { "term\($0)" }
        XCTAssertEqual(CustomVocabulary.selected(hundred, limits: .scribeUpload).count, 100)
        XCTAssertEqual(CustomVocabulary.selected(hundred, limits: .scribeRealtime).count, 50)
        XCTAssertEqual(CustomVocabulary.selected(hundred, limits: .appleContextualStrings).count, 100)
        XCTAssertEqual(CustomVocabulary.selected(["twenty-one characters"], limits: .scribeRealtime), [])
    }
}

// MARK: - Vocabulary on the wire

final class VocabularyWireTests: XCTestCase {
    private let vocabulary = ["SpeechText", "C++", "R&D", "a = b", "an overly long realtime term"]

    private func config(_ provider: STTProviderType, elevenLabsModel: String = "scribe_v2",
                        openAISTTModel: String = "gpt-transcribe") -> RecordingConfiguration {
        var configuration = RecordingConfiguration(provider: provider, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "whisper-large-v3-turbo", .elevenLabs: elevenLabsModel, .openAI: openAISTTModel])
        configuration.vocabulary = vocabulary
        return configuration
    }

    // MARK: Which models are sent a list

    func testOnlyListParametersAreSent() {
        XCTAssertEqual(config(.groq).liveVocabulary, [])
        XCTAssertEqual(config(.groq).batchVocabulary, [])
        XCTAssertEqual(config(.local).batchVocabulary, [])
        XCTAssertEqual(config(.openai, openAISTTModel: "gpt-4o-mini-transcribe").batchVocabulary, [])
        XCTAssertEqual(config(.openai).batchVocabulary, vocabulary)
        XCTAssertEqual(config(.elevenlabs).batchVocabulary, vocabulary)
        // Apple's live recogniser takes them; its upload (to Groq) does not.
        XCTAssertEqual(config(.apple).liveVocabulary, vocabulary)
        XCTAssertEqual(config(.apple).batchVocabulary, [])
    }

    func testARealtimeModelAndItsFallbackEachGetTheirOwnFit() {
        let scribe = config(.elevenlabs, elevenLabsModel: elevenLabsRealtimeModel)
        XCTAssertFalse(scribe.liveVocabulary.contains("an overly long realtime term"))
        XCTAssertTrue(scribe.batchVocabulary.contains("an overly long realtime term"))
        XCTAssertEqual(config(.openai, openAISTTModel: openAIRealtimeSTTModel).liveVocabulary, vocabulary)
    }

    func testAnUnlistedModelIsSentNothing() {
        XCTAssertEqual(sttModel(vendor: .openAI, id: "whisper-1").vocabulary, .none)
        XCTAssertEqual(sttModel(vendor: .elevenLabs, id: "scribe_v9").vocabulary, .none)
        XCTAssertEqual(config(.openai, openAISTTModel: "whisper-1").batchVocabulary, [])
    }

    func testEveryLocalAndGroqModelTakesNone() {
        for model in knownSTTModels(of: .local) + knownSTTModels(of: .groq) {
            XCTAssertEqual(model.vocabulary, .none, model.id)
        }
    }

    // MARK: Uploads

    private func fields(_ body: Data, named name: String) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        return text.components(separatedBy: marker).dropFirst().map {
            String($0[..<$0.range(of: "\r\n")!.lowerBound])
        }
    }

    private let part = (filename: "recording.flac", mimeType: "audio/flac")

    func testScribeUploadRepeatsTheKeytermsField() {
        let body = ElevenLabsTranscriber.multipartBody(boundary: "B", audio: Data([1]), part: part,
                                                       model: "scribe_v2", language: nil,
                                                       keyterms: ["SpeechText", "C++"])
        XCTAssertEqual(fields(body, named: "keyterms"), ["SpeechText", "C++"])
    }

    func testOpenAIUploadSendsKeywordsAsAnArray() {
        let body = OpenAICompatibleTranscriber.multipartBody(boundary: "B", audio: Data([1]), part: part, upload: Provider.openAI.descriptor.speechUpload!,
                                                            model: "gpt-transcribe", language: "uk",
                                                            prompt: "unsent", keywords: ["SpeechText", "R&D"])
        XCTAssertEqual(fields(body, named: "keywords[]"), ["SpeechText", "R&D"])
        XCTAssertEqual(fields(body, named: "language"), ["uk"])
    }

    /// The owner's promise: nothing changes for anyone until they add terms.
    func testNoVocabularyMeansNoFieldAtAll() {
        let scribe = String(decoding: ElevenLabsTranscriber.multipartBody(
            boundary: "B", audio: Data([1]), part: part, model: "scribe_v2", language: nil, keyterms: []), as: UTF8.self)
        let openAI = String(decoding: OpenAICompatibleTranscriber.multipartBody(
            boundary: "B", audio: Data([1]), part: part, upload: Provider.openAI.descriptor.speechUpload!,
            model: "gpt-transcribe", language: nil, prompt: nil, keywords: []), as: UTF8.self)
        XCTAssertFalse(scribe.contains("keyterms"))
        XCTAssertFalse(openAI.contains("keywords"))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.realtimeURL(model: elevenLabsRealtimeModel, languages: [], keyterms: [])
            .absoluteString.contains("keyterms"))
        let session = OpenAIRealtimeTranscriber.encodeSessionUpdate(model: openAIRealtimeSTTModel, languages: [],
                                                                 sampleRate: 24_000, keywords: [])
        XCTAssertFalse(session?.contains("keywords") ?? true)
    }

    // MARK: Sockets

    func testScribeRealtimeEscapesWhatAQueryStringWouldMisread() throws {
        let url = ElevenLabsRealtimeTranscriber.realtimeURL(model: elevenLabsRealtimeModel, languages: ["uk"],
                                                         keyterms: ["C++", "R&D", "a = b"])
        let query = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertTrue(query.contains("keyterms=C%2B%2B"), query)
        XCTAssertTrue(query.contains("keyterms=R%26D"), query)
        XCTAssertTrue(query.contains("keyterms=a%20%3D%20b"), query)
        XCTAssertEqual(url.scheme, "wss")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "keyterms" }.map(\.value), ["C++", "R&D", "a = b"])
        XCTAssertEqual(items.first { $0.name == "language_code" }?.value, "uk")
        XCTAssertEqual(items.first { $0.name == "model_id" }?.value, elevenLabsRealtimeModel)
    }

    func testOpenAIRealtimeCarriesKeywordsInTheTranscriptionBlock() throws {
        let raw = try XCTUnwrap(OpenAIRealtimeTranscriber.encodeSessionUpdate(
            model: openAIRealtimeSTTModel, languages: [], sampleRate: 24_000, keywords: ["SpeechText", "C++"]))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let transcription = try XCTUnwrap(((((json["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"]
            as? [String: Any])?["transcription"]) as? [String: Any])
        XCTAssertEqual(transcription["keywords"] as? [String], ["SpeechText", "C++"])
    }
}

// MARK: - Replacements and the Dictionary's corrections (TextReplacements.swift)

final class TextReplacementTests: XCTestCase {
    private func rules(_ pairs: [(String, String)]) -> TextReplacementRules {
        TextReplacementRules(pairs.map { TextReplacementPair(replace: $0.0, with: $0.1) })
    }

    func testWholeWordsInAnyCaseWrittenAsTyped() {
        let r = rules([("gpt", "GPT"), ("кубектл", "kubectl")])
        XCTAssertEqual(r.applied(to: "Gpt і КУБЕКТЛ, gpt."), "GPT і kubectl, GPT.")
        XCTAssertEqual(r.applied(to: "gpts, chat-gpt, gpt-4, gpt'"), "gpts, chat-gpt, gpt-4, gpt'",
                       "not inside a word, a hyphenated compound or across an apostrophe")
    }

    func testCyrillicWordEdgesAreUnicodeAware() {
        let r = rules([("об", "OB"), ("бот", "Bot")])
        XCTAssertEqual(r.applied(to: "об'єкт, чат-бот, бот, обід"), "об'єкт, чат-бот, Bot, обід")
    }

    func testAnyOfTheThreeApostrophesMatches() {
        let r = rules([("Мар'яна", "Maryana")])
        XCTAssertEqual(r.applied(to: "Мар'яна, Мар’яна, Марʼяна"), "Maryana, Maryana, Maryana")
    }

    func testSeveralWordsMatchAcrossAnyWhitespaceButNotPunctuation() {
        let r = rules([("send it to the team", "📨"), ("chat gpt", "ChatGPT")])
        XCTAssertEqual(r.applied(to: "Open Chat  GPT and send it to\nthe team"), "Open ChatGPT and 📨")
        XCTAssertEqual(r.applied(to: "chat, gpt"), "chat, gpt")
    }

    func testTheLongerRuleWinsAndOutputIsNeverMatchedAgain() {
        let r = rules([("chat", "Talk"), ("chat gpt", "ChatGPT"), ("Talk", "Speak")])
        XCTAssertEqual(r.applied(to: "chat gpt and chat"), "ChatGPT and Talk")
    }

    func testTheTableComesBeforeTheDictionaryAndCapitalsArePutBack() {
        let entries = [VocabularyEntry(term: "SpeechText", misheard: ["speech text", "кома"]), VocabularyEntry(term: "iPhone")]
        let r = TextReplacementRules(entries: entries, replacements: [TextReplacementPair(replace: "кома", with: ",")])
        XCTAssertEqual(r.applied(to: "speech text кома IPHONE"), "SpeechText , iPhone",
                       "the table's own rule for a source wins")
    }

    func testARuleThePageWouldRefuseIsSkipped() {
        let r = rules([("", "Y"), ("z", " "), ("gpt", "GPT"), ("GPT", "Other")])
        XCTAssertEqual(r.applied(to: "z gpt"), "z GPT")
        XCTAssertTrue(TextReplacementRules([]).isEmpty)
    }

    func testEntryChecks() {
        let existing = [TextReplacementPair(replace: "Chat GPT", with: "ChatGPT")]
        XCTAssertEqual(TextReplacements.entryProblem(replace: " ", with: "x", existing: []), .emptyReplace)
        XCTAssertEqual(TextReplacements.entryProblem(replace: "a", with: " ", existing: []), .emptyWith)
        XCTAssertEqual(TextReplacements.entryProblem(replace: "...", with: "x", existing: []), .noWord)
        XCTAssertEqual(TextReplacements.entryProblem(replace: "chat  gpt", with: "x", existing: existing), .duplicate)
        XCTAssertNil(TextReplacements.entryProblem(replace: "три слова тут", with: "x", existing: existing))
        let stored = TextReplacements.normalized(replace: " chat\n gpt ", with: " ChatGPT ")
        XCTAssertEqual(stored.replace, "chat gpt")
        XCTAssertEqual(stored.with, "ChatGPT")
        XCTAssertEqual(TextReplacements.decode(TextReplacements.encode([stored])), [stored])
        XCTAssertEqual(TextReplacements.decode(Data("nope".utf8)), [])
    }

    func testAFinishedSegmentGetsBothAndItsDashesLast() {
        var configuration = RecordingConfiguration(provider: .groq, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "", .elevenLabs: ""])
        configuration.dictionary = [VocabularyEntry(term: "SpeechText", misheard: ["спіч текст"])]
        configuration.replacements = [TextReplacementPair(replace: "тире", with: "—")]
        XCTAssertEqual(configuration.finished("е-е-е, спіч текст тире гпт"), "SpeechText – гпт")
        XCTAssertEqual(configuration.cleaned("спіч текст"), "спіч текст", "the live text is not corrected")
    }

    func testEveryLLMReplyIsCorrected() {
        let reply = TextRefinementService.polishedReply(
            "Open Speech Text — now", dictionary: [VocabularyEntry(term: "SpeechText", misheard: ["speech text"])],
            replacements: [TextReplacementPair(replace: "now", with: "today")], dashStyle: .hyphen)
        XCTAssertEqual(reply, "Open SpeechText - today")
    }
}

// MARK: - History's counts, kept (CustomVocabulary.swift)

/// `HistoryTermCounts` keeps between dictations what `CustomVocabulary.ranked` used to count
/// afresh at every start. It must count exactly what the full count does, whatever History
/// did in between — records added at the front, rewritten by a retry, trimmed from the end
/// or deleted — and whatever the Dictionary asks for.
final class HistoryTermCountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func term(_ text: String, daysAgo: Double) -> VocabularyEntry {
        VocabularyEntry(term: text, added: now.addingTimeInterval(-daysAgo * 86_400))
    }

    /// The count `ranked` made before it matched word by word: each record's `searchable`
    /// text searched for each needle with Foundation's `range(of:)`, an occurrence beginning
    /// at the space the last one ended on. Kept here as what the word-by-word count must give.
    private func searchedCount(_ needles: Set<String>, in texts: [String]) -> [String: Int] {
        let haystacks = texts.map(CustomVocabulary.searchable)
        return Dictionary(uniqueKeysWithValues: needles.map { needle in
            (needle, haystacks.reduce(0) { total, haystack in
                var count = 0
                var searchRange = haystack.startIndex..<haystack.endIndex
                while let found = haystack.range(of: needle, range: searchRange) {
                    count += 1
                    searchRange = haystack.index(before: found.upperBound)..<haystack.endIndex
                }
                return total + count
            })
        })
    }

    func testWordsAreCountedAsSearchingTheTextCountedThem() {
        let texts = ["a a a a", "A, a. A!", "API api-API rapid", "AC-42 ac 42 ac42 AC‑42", "Café cafe\u{301} CAFÉ cafe",
                     "об'єкт об’єкт обʼєкт", "Нова пошта, нова — пошта; Нова Пошта", "", "…", "ok ok ok ok ok",
                     "kubernetes cluster kubernetes kubernetes cluster", "x y x y x y x"]
        let needles = Set(["a", "a a", "api", "ac 42", "ac42", "café", "об єкт", "нова пошта", "ok ok", "kubernetes",
                           "kubernetes cluster", "x y x", "missing"].map(CustomVocabulary.searchable))
        XCTAssertEqual(CustomVocabulary.uses(of: needles, in: texts), searchedCount(needles, in: texts))
        XCTAssertEqual(CustomVocabulary.uses(of: needles, in: texts)[" a a "], 2 + 1, "\"a a\" occurs twice in \"a a a a\"")
        let synthetic = SyntheticHistory.texts(count: 300)
        let terms = Set(SyntheticHistory.terms.map(CustomVocabulary.searchable))
        XCTAssertEqual(CustomVocabulary.uses(of: terms, in: synthetic), searchedCount(terms, in: synthetic))
    }

    func testKeptCountsAreAFreshCountWhateverHistoryDid() {
        let counts = HistoryTermCounts()
        var history: [(id: UUID, text: String)] = [
            (UUID(), "Kubernetes, and kubernetes again"), (UUID(), "A rapid API change"),
            (UUID(), "ac-42 shipped, AC 42 too"), (UUID(), "ok ok ok"), (UUID(), "Kubernetes"),
        ]
        var needles: Set<String> = [" kubernetes ", " api ", " ac 42 ", " ok "]
        func check(_ step: String) {
            XCTAssertEqual(counts.uses(of: needles, in: history),
                           CustomVocabulary.uses(of: needles, in: history.map(\.text)), step)
        }
        check("the first look")
        XCTAssertEqual(counts.uses(of: needles, in: history)[" ok "], 3, "a word said three times in a row counts three")
        check("nothing changed")
        history.insert((UUID(), "API, API and Kubernetes"), at: 0)
        check("a dictation added")
        history[2].text = "kubernetes once more"
        check("a retry rewrote a record")
        history.removeLast()
        check("trimmed from the end")
        history.remove(at: 1)
        check("deleted in the middle")
        needles.insert(" rapid ")
        check("a word past its first week")
        needles.remove(" api ")
        needles.insert(" apis ")
        check("a word renamed")
        history.insert((UUID(), "rapid APIs"), at: 0)
        check("a dictation added after the rename")
        history = []
        check("History cleared")
    }

    func testRankingWithKeptCountsIsTheRankingWithAFreshCount() {
        let terms = [term("API", daysAgo: 20), term("Kubernetes", daysAgo: 30), term("AC-42", daysAgo: 40),
                     term("—", daysAgo: 50), term("New", daysAgo: 1)]
        let history: [(id: UUID, text: String)] = [(UUID(), "A rapid rapid change"),
                                                    (UUID(), "kubernetes, and Kubernetes again"), (UUID(), "ac-42 shipped")]
        let counts = HistoryTermCounts()
        let kept = CustomVocabulary.ranked(terms, now: now, rankByUse: true, uses: { counts.uses(of: $0, in: history) })
        XCTAssertEqual(kept, CustomVocabulary.ranked(terms, now: now, rankByUse: true, historyTexts: { history.map(\.text) }))
        XCTAssertEqual(kept, ["New", "Kubernetes", "AC-42", "API", "—"])
    }

    func testHistoryIsNotAskedWhenNothingIsRankedByIt() {
        let notAsked: (Set<String>) -> [String: Int] = { _ in XCTFail("History read"); return [:] }
        let terms = [term("B", daysAgo: 30), term("A", daysAgo: 20)]
        XCTAssertEqual(CustomVocabulary.ranked(terms, now: now, rankByUse: false, uses: notAsked), ["A", "B"])
        // One older word has nothing to be ranked against.
        let one = [term("Old", daysAgo: 30), term("New", daysAgo: 1)]
        XCTAssertEqual(CustomVocabulary.ranked(one, now: now, rankByUse: true, uses: notAsked), ["New", "Old"])
    }

    /// What a dictation start paid before the counts were kept, and pays now, at the
    /// History a year or two of dictations reaches. Printed, never asserted — a machine's
    /// speed is not a test's business.
    func testTimingsAtTwentyThousandRecords() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEECHTEXT_PERF"] == "1",
                          "set SPEECHTEXT_PERF=1 to time History at scale")
        var history = SyntheticHistory.texts(count: 20_000).map { (id: UUID(), text: $0) }
        let needles = Set(SyntheticHistory.terms.map(CustomVocabulary.searchable))
        let counts = HistoryTermCounts()
        let (searched, searchedTime) = SyntheticHistory.timed { searchedCount(needles, in: history.map(\.text)) }
        let (full, fullTime) = SyntheticHistory.timed { CustomVocabulary.uses(of: needles, in: history.map(\.text)) }
        let (first, firstTime) = SyntheticHistory.timed { counts.uses(of: needles, in: history) }
        let (_, sameTime) = SyntheticHistory.timed { counts.uses(of: needles, in: history) }
        history.insert((UUID(), "Olena sent the JSON about Kubernetes to Petro."), at: 0)
        let (added, addedTime) = SyntheticHistory.timed { counts.uses(of: needles, in: history) }
        XCTAssertEqual(full, searched)
        XCTAssertEqual(first, full)
        XCTAssertEqual(added, CustomVocabulary.uses(of: needles, in: history.map(\.text)))
        print(String(format: """
            perf ranking (20000 records, %d older words): before, searched %.1f ms (a start made two: %.1f ms); \
            now counted word by word %.1f ms, kept — first look %.1f ms, nothing changed %.2f ms, \
            one dictation added %.2f ms
            """, needles.count, searchedTime, 2 * searchedTime, fullTime, firstTime, sameTime, addedTime))
    }
}

/// History at the scale a year or two of dictations reaches — Ukrainian and English, names
/// and terms among ordinary words — made the same way on every run, for the timings
/// `SPEECHTEXT_PERF=1` prints.
enum SyntheticHistory {
    /// Thirty Dictionary words, some said often, some rarely, some never.
    static let terms = ["Olena", "Petro", "Figma", "Slack", "JSON", "iPhone", "SpeechText", "Kubernetes", "API",
                        "AC-42", "Groq", "Scribe", "Parakeet", "WhisperKit", "FluidAudio", "Sparkle", "TestFlight",
                        "Xcode", "GitHub", "Linear", "Notion", "Postgres", "Redis", "gRPC", "OAuth", "Київстар",
                        "Монобанк", "Дія", "Укрпошта", "Нова пошта"]

    private static let words = ["і", "що", "це", "ми", "треба", "зробити", "завтра", "сьогодні", "проєкт", "зустріч",
                                "лист", "кластер", "перевір", "будь", "ласка", "дякую", "коли", "буде", "готово",
                                "the", "and", "send", "it", "to", "with", "about", "release", "build", "please",
                                "check", "tomorrow", "meeting", "notes", "draft", "a", "of", "for", "we", "need"]
    private static let names = ["Olena", "Petro", "Figma", "Slack", "JSON", "iPhone", "SpeechText", "Kubernetes",
                                "API", "AC-42", "Groq", "GitHub", "Київстар", "Дія", "Нова пошта", "Mykola", "Iryna"]

    static func texts(count: Int) -> [String] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        return (0..<count).map { _ in
            var sentence: [String] = []
            for index in 0..<(8 + next(32)) {
                var word = next(8) == 0 ? names[next(names.count)] : words[next(words.count)]
                if index == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
                if next(9) == 0 { word += next(3) == 0 ? "." : "," }
                sentence.append(word)
            }
            return sentence.joined(separator: " ") + "."
        }
    }

    /// `work`'s result, and how long it took in milliseconds.
    static func timed<T>(_ work: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
