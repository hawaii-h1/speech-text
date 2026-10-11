// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The audio corpus through the real cloud engines (#80). Skipped unless the run asks
/// for it: it costs money, needs the network, and takes about as long as the clips.
///
///     SPEECHTEXT_LIVE=1              required
///     SPEECHTEXT_CORPUS=<dir>        where <clip>.wav lives; the descriptions are in
///                                    SpeechTextTests/Audio/<clip>.json
///     ELEVENLABS_API_KEY, OPENAI_API_KEY, GROQ_API_KEY
///                                    from the environment only, never from the app's
///                                    settings; an engine without its key is a "no key" row
///     SPEECHTEXT_ENGINES=openAI/gpt-live-transcribe,…   optional subset (vendor/model)
///     SPEECHTEXT_CLIPS=pause-uk,…    optional subset
///     SPEECHTEXT_RUN_DIR=<dir>       optional; a new docs/testing-runs/<date> otherwise
///
/// An unhosted test bundle does not inherit the shell's environment: `xcodebuild` passes
/// `TEST_RUNNER_<NAME>` through as `<NAME>`, which `scripts/evaluate.sh` does. The local
/// engines are the `SpeechTextEvaluation` tool's half of the same run.
final class LiveProviderTests: XCTestCase {
    @MainActor
    func testCorpusThroughCloudEngines() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SPEECHTEXT_LIVE"] == "1", "set SPEECHTEXT_LIVE=1 to run the live corpus")
        let corpus = try XCTUnwrap(environment["SPEECHTEXT_CORPUS"].map { URL(fileURLWithPath: $0) },
                                   "SPEECHTEXT_CORPUS names the folder of <clip>.wav files")

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let descriptions = try CorpusClip.load(from: repository.appendingPathComponent("SpeechText/SpeechTextTests/Audio"))
        let clips = CorpusClip.recordings(of: descriptions, in: corpus)
            .filter { $0.isSelected(by: Self.names(environment["SPEECHTEXT_CLIPS"])) }
        let engines = CorpusEngine.all
            .filter { engine in
                let names = Self.names(environment["SPEECHTEXT_ENGINES"])
                return !engine.isLocal && (names.isEmpty || names.contains(engine.id))
            }
        var folder = environment["SPEECHTEXT_RUN_DIR"].map { CorpusRunFolder(url: URL(fileURLWithPath: $0)) }
            ?? CorpusRunFolder.new(in: repository)
        folder.baseline = CorpusRunFolder.previous(in: repository, before: folder.url)?.url
        let keys = ProviderKeys.fromEnvironment(environment)
        XCTAssertFalse(clips.isEmpty, "no clip descriptions selected")
        // What the app registers at launch: without it no word cut in two is glued back.
        let isWord = TranscriptJoin.isWord
        registerSpellCheckedJoins()
        defer { TranscriptJoin.isWord = isWord }

        var results = folder.earlierResults(runner: "cloud", except: clips)
        for clip in clips {
            let audio = try? TapAudio(clip: clip, in: corpus)
            for engine in engines {
                for pass in clip.passes {
                    var result: CorpusResult
                    if audio == nil {
                        result = CorpusResult(clip: clip.name, engine: engine.id, engineName: engine.name,
                                              language: pass.label, status: .noAudio)
                    } else if let missing = engine.unavailable(keys: keys) {
                        result = CorpusResult(clip: clip.name, engine: engine.id, engineName: engine.name,
                                              language: pass.label, status: missing)
                    } else {
                        result = await LiveDictation.run(clip: clip, audio: audio!, engine: engine, pass: pass,
                                                         keys: keys, traceDirectory: folder.traces)
                    }
                    results.append(result)
                    // Written after every row, so a run stopped half-way keeps what it measured.
                    try folder.write(results, runner: "cloud")
                    for failure in result.failures {
                        XCTFail("\(clip.name) · \(engine.id) · \(result.language): \(failure)")
                    }
                }
            }
        }
        print("Corpus run: \(folder.url.path)/summary.md")
    }

    private static func names(_ list: String?) -> [String] {
        (list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The corpus's measures, offline.
final class CorpusMeasureTests: XCTestCase {
    func testWordsIgnorePunctuationCaseAndApostropheSpelling() {
        XCTAssertEqual(CorpusMeasure.words("Прив'язка, «Привʼязка» — ПРИВ’ЯЗКА!"),
                       ["прив'язка", "прив'язка", "прив'язка"])
        XCTAssertEqual(CorpusMeasure.words("well-known — 2–5"), ["well-known", "2", "5"])
    }

    func testWordErrorRateCountsSubstitutionsInsertionsAndDeletions() {
        XCTAssertEqual(CorpusMeasure.wordErrorRate(expected: "раз два три чотири", actual: "Раз, два, три, чотири."), 0)
        XCTAssertEqual(CorpusMeasure.wordErrorRate(expected: "раз два три чотири", actual: "раз два три"), 0.25)
        XCTAssertEqual(CorpusMeasure.wordErrorRate(expected: "раз два", actual: "раз три два"), 0.5)
        XCTAssertEqual(CorpusMeasure.wordErrorRate(expected: "раз два", actual: ""), 1)
        XCTAssertNil(CorpusMeasure.wordErrorRate(expected: "", actual: "Evet."))
    }

    /// #67: the restatement joined on as new speech.
    func testARestatementJoinedOnIsARepeatedPhrase() {
        let said = "Так, треба перевірити шорткати, де їх немає. Можливо, FN+Q, A, W, E."
        let pasted = said + " Так, треба перевірити шорткати, де їх немає. Можливо, FN плюс Q, A, W."
        XCTAssertTrue(CorpusMeasure.repeatedPhrases(expected: said, actual: pasted)
            .contains("так потрібно змінити шорткати"))
        XCTAssertEqual(CorpusMeasure.repeatedPhrases(expected: said, actual: said), [])
    }

    func testAPhraseTheSpeakerRepeatedIsNotFlagged() {
        let said = "раз два три чотири і ще раз раз два три чотири"
        XCTAssertEqual(CorpusMeasure.repeatedPhrases(expected: said, actual: said), [])
    }

    /// The Russian-spelled word the alphabet check cannot see (GPT Live, 27.09).
    func testAWordWrittenInPlaceOfTheOneSaidIsListed() {
        XCTAssertEqual(CorpusMeasure.substitutions(expected: "Привіт, це перевірка обв'язки корпусу.",
                                                   actual: "Привет, це перевірка обов'язки корпусу."),
                       ["привіт → привет", "обв'язки → обов'язки"])
        XCTAssertEqual(CorpusMeasure.substitutions(expected: "раз два три", actual: "раз два три чотири"), [])
    }

    func testASilenceClipIsCutFromTheRoomTone() throws {
        let clip = try JSONDecoder().decode(CorpusClip.self, from: Data("""
            {"expected": "", "language": "uk", "source": "room-tone", "seconds": 0.2}
            """.utf8))
        XCTAssertEqual(clip.audioFile, "room-tone.wav")
        XCTAssertEqual(clip.seconds, 0.2)
        XCTAssertTrue(clip.expectsNothing)
    }

    func testLanguageIsJudgedByTheAlphabet() {
        XCTAssertNil(CorpusMeasure.languageProblem(language: "uk", actual: "Привіт, як справи? OK."))
        XCTAssertEqual(CorpusMeasure.languageProblem(language: "uk", actual: "Это не так"), "Russian letters э")
        XCTAssertEqual(CorpusMeasure.languageProblem(language: "uk", actual: "Pryvit yak spravy"), "mostly not Cyrillic")
        XCTAssertEqual(CorpusMeasure.languageProblem(language: "en", actual: "Hello привіт"), "Cyrillic in English")
        XCTAssertNil(CorpusMeasure.languageProblem(language: "mixed", actual: "Hello привіт"))
    }

    func testSilenceMustPasteNothingAndSpeechMustPasteSomething() {
        let silence = CorpusClip(expected: "", language: "uk")
        XCTAssertEqual(CorpusChecks.failures(clip: silence, clipSeconds: 1, pasted: nil, error: nil), [])
        XCTAssertEqual(CorpusChecks.failures(clip: silence, clipSeconds: 1, pasted: "Evet.", error: nil).count, 1)

        let tooShort = CorpusClip(expected: "так", language: "uk")
        XCTAssertEqual(CorpusChecks.failures(clip: tooShort, clipSeconds: 0.2, pasted: "Так.", error: nil).count, 1)

        let speech = CorpusClip(expected: "раз два три", language: "uk", maxWER: 0.4)
        XCTAssertEqual(CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: nil, error: "HTTP 500"),
                       ["nothing pasted: HTTP 500"])
        XCTAssertEqual(CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: "Раз, два, три.", error: nil), [])
        XCTAssertEqual(CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: "Раз.", error: nil), ["WER 0.67 over 0.40"])
    }

    func testEveryRecordingOfADescriptionIsARow() throws {
        let corpus = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: corpus) }
        for file in ["uk-pause.wav", "uk-pause@builtin.wav", "mixed@english.wav", "uk-pause-long.wav"] {
            FileManager.default.createFile(atPath: corpus.appendingPathComponent(file).path, contents: Data())
        }
        let clips = [CorpusClip(name: "uk-pause", expected: "раз", language: "uk"),
                     CorpusClip(name: "mixed", expected: "раз", language: "mixed"),
                     CorpusClip(name: "uk-names", expected: "раз", language: "uk"),
                     CorpusClip(name: "silence", expected: "", language: "uk", source: "room-tone", seconds: 1)]
        let rows = CorpusClip.recordings(of: clips, in: corpus)
        XCTAssertEqual(rows.map(\.name), ["uk-pause", "uk-pause@builtin", "mixed@english", "uk-names", "silence"])
        XCTAssertEqual(rows[1].audioFile, "uk-pause@builtin.wav")
        XCTAssertEqual(rows[1].descriptionName, "uk-pause")
        XCTAssertEqual(rows[4].audioFile, "room-tone.wav")
        XCTAssertTrue(rows[1].isSelected(by: ["uk-pause"]))
        XCTAssertFalse(rows[0].isSelected(by: ["uk-pause@builtin"]))
    }

    func testAClipWithAVocabularyGetsADictionaryPass() {
        var clip = CorpusClip(expected: "раз", language: "mixed", forcedLanguages: ["uk"])
        XCTAssertEqual(clip.passes.map(\.label), ["auto", "uk"])
        clip.vocabulary = ["Grafana"]
        XCTAssertEqual(clip.passes.map(\.label), ["auto", "uk", "auto + dictionary"])
        XCTAssertEqual(clip.dictionaryEntries.map(\.term), ["Grafana"])
    }

    func testSentencesGluedAtABoundaryAreFound() {
        XCTAssertEqual(CorpusMeasure.gluedSentences(expected: "Це перевірка. Закінчую.",
                                                    actual: "Це перевірка.Закінчую."), ["перевірка.Закінчую"])
        XCTAssertEqual(CorpusMeasure.gluedSentences(expected: "Оновив Node.js.", actual: "Оновив Node.js."), [])
        XCTAssertEqual(CorpusMeasure.gluedSentences(expected: "", actual: "Ціна 2,5 гривні. Так."), [])
    }

    func testAKnownHallucinationInsideTheTextIsFound() {
        XCTAssertEqual(CorpusMeasure.knownHallucinations(expected: "Перевірка.",
                                                         actual: "Перевірка. Дякую за перегляд."), ["дякую за перегляд"])
        XCTAssertEqual(CorpusMeasure.knownHallucinations(expected: "Перевірка.", actual: "Перевірка, дякую."), [])
        XCTAssertEqual(CorpusMeasure.knownHallucinations(expected: "Скажи: дякую за перегляд.",
                                                         actual: "Скажи: дякую за перегляд."), [])
    }

    func testEveryFailureACheckReportsHasAKind() {
        let silence = CorpusClip(expected: "", language: "uk")
        let speech = CorpusClip(expected: "Це перевірка. Закінчую тут зараз і далі.", language: "uk", maxWER: 0.1)
        let english = CorpusClip(expected: "Hello there", language: "en")
        let failures = CorpusChecks.failures(clip: silence, clipSeconds: 1, pasted: "Evet.", error: nil)
            + CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: nil, error: nil)
            + CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: nil, error: "HTTP 500")
            + CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: "Это перевірка.Закінчую тут зараз і далі "
                                    + "закінчую тут зараз і далі. Дякую за перегляд.", error: nil)
            + CorpusChecks.failures(clip: speech, clipSeconds: 3, pasted: "Tse perevirka", error: nil)
            + CorpusChecks.failures(clip: english, clipSeconds: 3, pasted: "Hello привіт", error: nil)
        XCTAssertEqual(Set(failures.map(CorpusChecks.kind(of:))),
                       ["pasted for nothing", "nothing pasted", "repeated", "WER over its bound", "language",
                        "glued", "hallucination"], "\(failures)")
    }

    private func result(_ clip: String, engine: String = "groq/w", language: String = "auto", wer: Double? = 0,
                        failures: [String] = [], pasted: String? = "раз", expected: String? = nil,
                        digest: String? = nil) -> CorpusResult {
        var result = CorpusResult(clip: clip, engine: engine, engineName: engine, language: language, status: .ran,
                                  pasted: pasted, wordErrorRate: wer, failures: failures)
        result.expected = expected
        result.audioDigest = digest
        return result
    }

    /// #167: each cell against its own earlier result.
    func testARunIsComparedWithTheOneBeforeCellByCell() {
        let previous = [
            result("a", wer: 0.30), result("b", wer: 0.30), result("c", wer: 0.50),
            result("d", wer: 0, failures: ["repeated: “раз два три чотири”"]),
            result("e", wer: 0, failures: ["glued: “раз.Два”"]),
            result("a", language: "uk", wer: 0.30),
            result("f", engine: "openAI/x", wer: 0), result("g", wer: nil, failures: [], pasted: nil),
        ]
        let current = [
            result("a", wer: 0.40),                                    // exactly 0.10: not a change
            result("b", wer: 0.41),                                    // worse
            result("c", wer: 0.20),                                    // better
            result("d", wer: 0, failures: ["repeated: “чотири п'ять шість сім”"]),  // same check, other words
            result("e", wer: 0, failures: ["Russian letters ы"]),       // one check passes, another fails
            result("a", language: "uk", wer: 0.30),
            result("f", engine: "openAI/x", wer: 0.30),               // worse, another engine
            result("g", wer: nil, failures: ["pasted “Evet.” for a clip that should produce nothing"], pasted: "Evet."),
            result("h", wer: 0.9),                                     // new
        ]
        let comparison = CorpusComparison(current, previous: previous, baseline: "2026-10-10_21-15")
        XCTAssertEqual(comparison.worse.map(\.result.clip), ["b", "e", "f", "g"])
        XCTAssertEqual(comparison.worse[0].reasons, ["WER 0.30 → 0.41"])
        XCTAssertEqual(comparison.worse[1].reasons, ["newly fails: language", "passes again: glued"])
        XCTAssertEqual(comparison.worse[3].reasons, ["newly fails: pasted for nothing"])
        XCTAssertEqual(comparison.better.map(\.result.clip), ["c"])
        XCTAssertEqual(comparison.better[0].reasons, ["WER 0.50 → 0.20"])
        XCTAssertEqual(comparison.new.map(\.clip), ["h"])
        XCTAssertEqual(comparison.mark(for: current[1]), "▼")
        XCTAssertEqual(comparison.mark(for: current[2]), "▲")
        XCTAssertNil(comparison.mark(for: current[0]))
    }

    func testAClipThatChangedIsNotCompared() {
        let said = "раз два три чотири"
        // Its text, kept by both runs.
        var comparison = CorpusComparison([result("a", wer: 0.9, expected: said + " п'ять")],
                                          previous: [result("a", wer: 0, expected: said)], baseline: "x")
        XCTAssertEqual(comparison.changedClips.map(\.clip), ["a"])
        XCTAssertTrue(comparison.worse.isEmpty)
        // Its recording.
        comparison = CorpusComparison([result("a", wer: 0.9, expected: said, digest: "1")],
                                      previous: [result("a", wer: 0, expected: said, digest: "2")], baseline: "x")
        XCTAssertEqual(comparison.changedClips.map(\.clip), ["a"])
        // A run from before either was kept: its answer measured against today's text.
        comparison = CorpusComparison([result("a", wer: 0.6, expected: said + " п'ять")],
                                      previous: [result("a", wer: 0, pasted: "раз два три чотири")], baseline: "x")
        XCTAssertEqual(comparison.changedClips.map(\.clip), ["a"])
        comparison = CorpusComparison([result("a", wer: 0.5, expected: said)],
                                      previous: [result("a", wer: 0, pasted: said)], baseline: "x")
        XCTAssertEqual(comparison.worse.map(\.result.clip), ["a"])
    }

    func testThePreviousRunIsTheLastOneBeforeThisRun() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")
        let runs = repository.appendingPathComponent("docs/testing-runs")
        defer { try? FileManager.default.removeItem(at: repository) }
        for (name, results) in [("2026-10-10_21-15", true), ("2026-10-11_11-47", true), ("2026-10-12_09-00", false)] {
            let folder = runs.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent(results ? "results-cloud.json" : "summary.md").path,
                                           contents: Data("[]".utf8))
        }
        // Not a git checkout, so every folder with results counts.
        XCTAssertEqual(CorpusRunFolder.previous(in: repository, before: URL(fileURLWithPath: "/tmp/st-corpus/now"))?
            .url.lastPathComponent, "2026-10-11_11-47")
        XCTAssertEqual(CorpusRunFolder.previous(in: repository, before: runs.appendingPathComponent("2026-10-12_09-00"))?
            .url.lastPathComponent, "2026-10-11_11-47")
        XCTAssertEqual(CorpusRunFolder.previous(in: repository, before: runs.appendingPathComponent("2026-10-11_11-47"))?
            .url.lastPathComponent, "2026-10-10_21-15")
        XCTAssertNil(CorpusRunFolder.previous(in: repository, before: runs.appendingPathComponent("2026-10-10_21-15")))
    }

    func testTheSummarySaysWhatChangedSinceThePreviousRun() {
        let previous = [result("uk-short", engine: "openAI/live", wer: 0), result("uk-pause", engine: "openAI/live", wer: 0.5)]
        let current = [result("uk-short", engine: "openAI/live", wer: 1, failures: ["mostly not Cyrillic"]),
                       result("uk-pause", engine: "openAI/live", wer: 0), result("uk-names", engine: "openAI/live", wer: 0)]
        let summary = CorpusSummary.render(current, comparison: CorpusComparison(current, previous: previous,
                                                                                 baseline: "2026-10-10_21-15"))
        XCTAssertTrue(summary.contains("## Since 2026-10-10_21-15\n\n1 worse, 1 better, 1 new."), summary)
        XCTAssertTrue(summary.contains("### Worse\n\n**openAI/live**\n\n- uk-short · auto: WER 0.00 → 1.00; newly fails: language\n"),
                      summary)
        XCTAssertTrue(summary.contains("- uk-pause · auto: WER 0.50 → 0.00\n"), summary)
        XCTAssertTrue(summary.contains("### New\n\n- **openAI/live**: uk-names · auto\n"), summary)
        XCTAssertTrue(summary.contains("| uk-short | 1.00 · — · — ❌ ▼ |"), summary)
        XCTAssertTrue(summary.contains("| uk-pause | 0.00 · — · — ▲ |"), summary)
    }

    func testTheSummaryIsATableOfClipsByEngine() {
        let results = [
            CorpusResult(clip: "pause-uk", engine: "openAI/gpt-live-transcribe", engineName: "GPT Live", language: "auto",
                         status: .ran, path: .fallback, pasted: "раз два", wordErrorRate: 0,
                         firstPartialSeconds: 0.84, stopToTextSeconds: 1.2),
            CorpusResult(clip: "pause-uk", engine: "local/parakeet-tdt-0.6b-v3", engineName: "Parakeet v3", language: "auto",
                         status: .notInstalled),
        ]
        let summary = CorpusSummary.render(results)
        XCTAssertTrue(summary.contains("| Clip | GPT Live | Parakeet v3 |"), summary)
        XCTAssertTrue(summary.contains("| pause-uk | 0.00 · 0.8s · 1.2s ↩ | not installed |"), summary)
    }
}
