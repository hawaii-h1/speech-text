// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// What a model row says about languages (#30, docs/design/model-details/): the catalogue's
/// lists, the count, the "No …" badge, the notes for the user's own languages, the
/// *Languages I speak* warning — and that no line names a language the user did not list.
final class ModelLanguageTests: XCTestCase {

    private func local(_ id: String) -> LocalSTTModel { localSTTModel(id: id)! }
    private let silent: (String) -> Bool? = { _ in nil }

    // MARK: The catalogue

    /// Every listed code is a BCP-47 language subtag — any, not only the app's — named once,
    /// read from an https page.
    func testEveryPublishedListIsWellFormed() {
        let coverages = sttModelCatalog.map(\.languages)
        for case .listed(let list) in coverages {
            XCTAssertEqual(list.source.scheme, "https", list.source.absoluteString)
            XCTAssertEqual(Set(list.codes).count, list.codes.count, list.source.absoluteString)
            for code in list.codes {
                XCTAssertNotNil(code.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression), code)
            }
            XCTAssertNotNil(list.checked.year)
        }
    }

    func testEachVendorsCoverage() {
        XCTAssertEqual(sttModel(vendor: .apple, id: appleSpeechModelID).languages, .decidedBySystem)
        for model in knownSTTModels(of: .openAI) {
            XCTAssertEqual(model.languages, .unpublished, model.id)
        }
        for model in knownSTTModels(of: .groq) {
            XCTAssertEqual(model.languages, whisperV3Languages, model.id)
        }
        for model in knownSTTModels(of: .elevenLabs) {
            XCTAssertEqual(model.languages, scribeLanguages, model.id)
        }
        // A local entry is derived from the local catalogue, notes included.
        for model in localSTTModels {
            let entry = sttModel(vendor: .local, id: model.id)
            XCTAssertEqual(entry.languages, model.languages, model.id)
            XCTAssertEqual(entry.languageNotes, model.languageNotes, model.id)
        }
    }

    /// An ID nobody checked, a cleared choice included, never warns — as it is never priced.
    func testAnUnlistedModelIsUnpublished() {
        for id in ["whisper-9", clearedModelChoice] {
            XCTAssertEqual(sttModel(vendor: .groq, id: id).languages, .unpublished, id)
            XCTAssertEqual(sttModel(vendor: .groq, id: id).languageNotes, [:])
        }
    }

    // MARK: The count

    func testTheSubtitleCountsTheLanguages() {
        XCTAssertEqual(languageCountLabel(parakeetV3Languages), "25 languages")
        XCTAssertEqual(languageCountLabel(local("phonon-2").languages), "English only")
        XCTAssertEqual(languageCountLabel(scribeLanguages), "90+ languages")
        XCTAssertEqual(languageCountLabel(whisperLanguages), "99 languages")
        XCTAssertEqual(languageCountLabel(whisperV3Languages), "100 languages")
        XCTAssertNil(languageCountLabel(.unpublished))
        XCTAssertNil(languageCountLabel(.decidedBySystem))
        let v3 = local(parakeetV3ModelID)
        XCTAssertEqual(speechModelSubtitle(v3), "\(v3.downloadSizeDescription) · 25 languages")
    }

    // MARK: The match and the badge

    func testAnEnglishOnlyModelLacksUkrainian() {
        let phonon = local("phonon-2").languages
        XCTAssertEqual(languageMatch(spoken: ["uk", "en"], coverage: phonon, onDevice: silent),
                       ["uk": .unsupported, "en": .supported])
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["uk"], coverage: phonon), "No Ukrainian")
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["en"], coverage: phonon), nil)
    }

    /// One badge names the first missing language in the user's order and counts the rest.
    func testTheBadgeNamesTheFirstAndCountsTheRest() {
        let phonon = local("phonon-2").languages
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["es", "uk", "en"], coverage: phonon), "No Spanish +1")
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["uk", "es", "ja"], coverage: phonon), "No Ukrainian +2")
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["ja", "uk"], coverage: parakeetV3Languages), "No Japanese")
    }

    /// Several users, one catalogue: each sees badges for their own languages and no other.
    func testBadgesFollowEachUsersLanguages() {
        let expected: [[String]: [String: String?]] = [
            ["uk", "en"]: [parakeetV3ModelID: nil, "phonon-2": "No Ukrainian", "openai_whisper-small_216MB": nil],
            ["es"]: [parakeetV3ModelID: nil, "phonon-2": "No Spanish", "openai_whisper-small_216MB": nil],
            ["ja", "en"]: [parakeetV3ModelID: "No Japanese", "phonon-2": "No Japanese", "openai_whisper-small_216MB": nil],
            ["no"]: [parakeetV3ModelID: "No Norwegian", "phonon-2": "No Norwegian", "openai_whisper-base": nil],
        ]
        for (spoken, rows) in expected {
            for (id, badge) in rows {
                XCTAssertEqual(missingLanguageBadgeText(spoken: spoken, coverage: local(id).languages), badge, "\(spoken) \(id)")
            }
        }
    }

    /// A user's code is matched on its language subtag, so a regional one finds its language.
    func testARegionalCodeMatchesItsLanguage() {
        XCTAssertEqual(languageMatch(spoken: ["uk-UA", "pt_BR"], coverage: parakeetV3Languages, onDevice: silent),
                       ["uk-UA": .supported, "pt_BR": .supported])
    }

    /// A model's list takes codes the app cannot state, and the count is the whole list's.
    func testAListTakesAnyLanguageCode() {
        let list = LanguageCoverage.listed(PublishedLanguages(
            codes: ["fil", "yue", "en"], source: URL(string: "https://example.com")!,
            checked: ModelRetirement.day(2026, 10, 17)))
        XCTAssertEqual(languageCountLabel(list), "3 languages")
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["en"], coverage: list), nil)
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["uk"], coverage: list), "No Ukrainian")
    }

    /// OpenAI publishes no list: unknown, and never a warning.
    func testAnUnpublishedListNeverWarns() {
        let model = sttModel(vendor: .openAI, id: "gpt-transcribe")
        XCTAssertEqual(languageMatch(spoken: ["uk"], coverage: model.languages, onDevice: { _ in false }), ["uk": .unknown])
        XCTAssertNil(missingLanguageBadgeText(spoken: ["uk", "es"], coverage: model.languages))
        XCTAssertNil(spokenLanguagesWarning(modelName: "GPT Transcribe", spoken: ["uk"], coverage: model.languages))
    }

    /// Apple's answer is macOS's: what it says, and silence when it cannot say.
    func testAppleFollowsWhatMacOSSays() {
        let apple = sttModel(vendor: .apple, id: appleSpeechModelID).languages
        let onDevice: (String) -> Bool? = { ["en": true, "es": false][$0] }
        XCTAssertEqual(languageMatch(spoken: ["en", "es", "uk"], coverage: apple, onDevice: onDevice),
                       ["en": .supported, "es": .unsupported, "uk": .unknown])
        XCTAssertEqual(missingLanguageBadgeText(spoken: ["en", "es", "uk"], coverage: apple, onDevice: onDevice),
                       "No Spanish on-device")
        XCTAssertEqual(spokenLanguagesWarning(modelName: "Apple Dictation", spoken: ["es"], coverage: apple, onDevice: onDevice),
                       "Apple Dictation can't take Spanish on this Mac.")
        // No known answer: nothing at all.
        XCTAssertNil(missingLanguageBadgeText(spoken: ["uk", "es"], coverage: apple, onDevice: silent))
        XCTAssertNil(spokenLanguagesWarning(modelName: "Apple Dictation", spoken: ["uk"], coverage: apple, onDevice: silent))
    }

    // MARK: Notes

    /// A measured weakness joins the line only for someone who speaks that language.
    func testANoteIsShownOnlyToItsSpeakers() {
        let small = local("openai_whisper-small_216MB")
        XCTAssertEqual(speechModelLine(small, spoken: ["uk"]), "Small and fast. Makes mistakes in Ukrainian.")
        XCTAssertEqual(speechModelLine(small, spoken: ["en", "uk-UA"]), "Small and fast. Makes mistakes in Ukrainian.")
        XCTAssertEqual(speechModelLine(small, spoken: ["es"]), "Small and fast.")
        XCTAssertEqual(speechModelLine(small, spoken: []), "Small and fast.")
        XCTAssertTrue(speechModelLine(local("parakeet-redux"), spoken: ["uk"]).hasSuffix("More mistakes in Ukrainian than Parakeet v3."))
    }

    /// With no languages stated there is no badge and no note anywhere.
    func testNoLanguagesStatedMeansNoBadgeAndNoNote() {
        for model in sttModelCatalog {
            XCTAssertNil(missingLanguageBadgeText(spoken: [], coverage: model.languages, onDevice: { _ in false }), model.id)
            XCTAssertEqual(lineWithLanguageNotes("Line.", notes: model.languageNotes, spoken: []), "Line.", model.id)
        }
        for model in localSTTModels {
            for note in model.languageNotes.values {
                XCTAssertFalse(speechModelLine(model, spoken: []).contains(note.text), model.id)
            }
        }
        for model in localChatModels {
            for note in model.languageNotes.values {
                XCTAssertFalse(aiModelLine(model, heavy: false, spoken: []).contains(note.text), model.id)
            }
        }
        XCTAssertNil(spokenLanguagesWarning(modelName: "Phonon-2", spoken: [], coverage: local("phonon-2").languages))
    }

    // MARK: The Languages I speak warning

    func testTheLanguagesCaptionWarnsAboutTheSelectedModel() {
        let phonon = local("phonon-2").languages
        XCTAssertEqual(spokenLanguagesWarning(modelName: "Phonon-2", spoken: ["uk", "en"], coverage: phonon),
                       "Phonon-2 can't take Ukrainian.")
        XCTAssertEqual(spokenLanguagesWarning(modelName: "Phonon-2", spoken: ["uk", "es", "ja"], coverage: phonon),
                       "Phonon-2 can't take Ukrainian, Spanish or Japanese.")
        XCTAssertNil(spokenLanguagesWarning(modelName: "Phonon-2", spoken: ["en"], coverage: phonon))
        XCTAssertNil(spokenLanguagesWarning(modelName: "Scribe v2", spoken: ["uk", "es"], coverage: scribeLanguages))
    }

    // MARK: No language names

    /// Every sentence a model row or setup card can show names no language but the user's
    /// own. This is what keeps the hard-coded lines of before #30 from coming back.
    func testNoRowLineNamesALanguageTheUserDidNotList() {
        let spokenSets: [[String]] = [[], ["uk"], ["es"], ["uk", "en"], ["ja"], ["en"], ["ru", "de"]]
        for spoken in spokenSets {
            var lines: [String] = [appleDictationLine, intelSpeechPlaceFacts, intelChatWarning]
            lines += localSTTModels.flatMap { [speechModelLine($0, spoken: spoken), $0.summary] }
            lines += sttModelCatalog.map { onlineSpeechModelLine($0, spoken: spoken) }
            lines += localChatModels.flatMap { [aiModelLine($0, heavy: false, spoken: spoken),
                                                aiModelLine($0, heavy: true, spoken: spoken), $0.summary] }
            lines += chatModelCatalog.map(chatModelLine)
            lines += Provider.allCases.flatMap { [onlineSpeechServiceLine($0), onlineAIServiceLine($0)] }
            lines += SetupCards.speech.flatMap { [$0.title, $0.subtitle, $0.detail] }
            lines += SetupCards.ai.flatMap { [$0.title, $0.subtitle] }
            for line in lines {
                for language in spokenLanguageCatalog where !spoken.contains(language.id) {
                    XCTAssertNil(line.range(of: "\\b\(language.displayName)\\b", options: .regularExpression),
                                 "“\(line)” names \(language.displayName) for \(spoken)")
                }
            }
        }
    }
}
