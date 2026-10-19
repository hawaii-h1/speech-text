// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

// MARK: - Transcript cleanup (TranscriptCleanup.swift)

final class TranscriptCleanupTests: XCTestCase {

    /// Taken from History: what Scribe realtime returned with `no_verbatim=true` on.
    private let recorded = [
        "Перевірю ще раз, як це працює ввечері. Тому всім пока, е-е-е, бувайте!",
        "Також скажу привіт. Ой, е-е-е, ні, не привіт, а пока.",
        "Ну, коротше, щось це таке. Е-е-е...",
        "Ти не пам’ятаєш, вона казала... Цей магазин чи тооо новий, чи то старий...",
        "Отже. А-а-а, ну, перше питанняяя: чи потрібно мені брати",
        "У мене все готово для звіту та, е-е, відправлення на пошту.",
        "Я нажав на кнопку, і я попав на... отримав доступ до форми",
    ]

    func testHesitationsGoWithTheirOwnPunctuation() {
        XCTAssertEqual(cleanedTranscript("Тому всім пока, е-е-е, бувайте!"), "Тому всім пока, бувайте!")
        XCTAssertEqual(cleanedTranscript("Ой, е-е-е, ні, не привіт"), "Ой, ні, не привіт")
        XCTAssertEqual(cleanedTranscript("щось це таке. Е-е-е..."), "щось це таке.")
        XCTAssertEqual(cleanedTranscript("I mean, uh, it's um fine, hmm."), "I mean, it's fine,")
    }

    func testAFillerThatOpenedASentenceHandsOnItsCapital() {
        XCTAssertEqual(cleanedTranscript("Отже. А-а-а, ну, перше"), "Отже. Ну, перше")
        XCTAssertEqual(cleanedTranscript("Еееем, давай"), "Давай")
    }

    /// Words, not sounds: a single or doubled vowel is a word ("а", "у", Russian "ее"),
    /// and so are the fillers that carry meaning elsewhere ("ну", "типу" — "цього типу").
    func testWordsThatLookLikeHesitationsAreKept() {
        let text = "а у ее ем ну цього типу ООО, 5 мм і 5 mm"
        XCTAssertEqual(cleanedTranscript(text), text)
    }

    func testStretchedLettersCollapseButDoublesStay() {
        XCTAssertEqual(cleanedTranscript("перше питанняяя, чи тооо знання"), "перше питання, чи то знання")
    }

    /// Scribe ends a segment its VAD closed on a short pause with "...", mid-sentence; a
    /// full stop there cut the sentence in two ("що ми. Зробили"). So the dots go, no
    /// full stop takes their place and the next word keeps the case it came with.
    func testTrailingEllipsisIsDroppedWithoutEndingTheSentence() {
        XCTAssertEqual(cleanedTranscript("які ти... описав в файлі"), "які ти описав в файлі")
        XCTAssertEqual(cleanedTranscript("я попав на… отримав"), "я попав на отримав")
        XCTAssertEqual(cleanedTranscript("вона казала... Цей"), "вона казала Цей")
        XCTAssertEqual(cleanedTranscript("справді?... так"), "справді? так")
        XCTAssertEqual(cleanedTranscript("що вони...\" далі"), "що вони\" далі")
        XCTAssertEqual(cleanedTranscript("що вони..."), "що вони")
        XCTAssertEqual(cleanedTranscript("діапазон 1...5 і далі ... ось"), "діапазон 1...5 і далі ось")
    }

    func testCleaningIsIdempotent() {
        for text in recorded {
            let once = cleanedTranscript(text)
            XCTAssertEqual(cleanedTranscript(once), once, text)
        }
    }

    /// The anti-duplication property: the engine cleans the *cumulative* committed text on
    /// every event and pastes the increment. If a longer transcript's cleaned form did not
    /// extend the shorter one's at a word boundary, the text already pasted would stop
    /// matching and the stop would deliver nothing.
    func testEveryWordPrefixCleansToAPrefixOfTheWhole() {
        for text in recorded {
            let words = text.split(separator: " ")
            var previous = ""
            for count in 1...words.count {
                let cleaned = cleanedTranscript(words.prefix(count).joined(separator: " "))
                XCTAssertTrue(cleaned == previous || previous.isEmpty || cleaned.hasPrefix(previous + " "),
                              "\"\(previous)\" is not extended by \"\(cleaned)\"")
                previous = cleaned
            }
        }
    }

    /// Out of contract, and pinned so it stays a known limit: committed text grows by whole
    /// segments, so a word is never extended in place. If a provider ever does that, this
    /// is the test that explains why delivery breaks.
    func testGrowthInsideAWordIsNotMonotone() {
        XCTAssertEqual(cleanedTranscript("Ой, е"), "Ой, е")
        XCTAssertEqual(cleanedTranscript("Ой, е-е"), "Ой,")
    }

    func testTheSettingCanTurnItOff() {
        var configuration = RecordingConfiguration(provider: .elevenlabs, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "", .elevenLabs: "scribe_v2_realtime"])
        XCTAssertEqual(configuration.cleaned("Ой, е-е-е, ні"), "Ой, ні")
        configuration.removesDisfluencies = false
        XCTAssertEqual(configuration.cleaned("Ой, е-е-е, ні"), "Ой, е-е-е, ні")
    }

    /// #166: Scribe answered a cough with hesitations alone; with them gone only «, ,» was
    /// left, and it was pasted.
    func testWhatIsLeftWithNoLetterOrDigitIsNothing() {
        let configuration = RecordingConfiguration(provider: .elevenlabs, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "", .elevenLabs: "scribe_v2"])
        XCTAssertEqual(configuration.cleaned("Um, um,"), "")
        XCTAssertEqual(configuration.cleaned("Хм, хм,"), "")
        XCTAssertEqual(configuration.cleaned("Е-е-е..."), "")
        XCTAssertEqual(configuration.finished("Um, um."), "")
        XCTAssertEqual(configuration.cleaned("Um, 42"), "42")
        XCTAssertEqual(configuration.cleaned("Ой, е-е-е, ні"), "Ой, ні")
    }
}

// MARK: - Dash style (TranscriptCleanup.swift)

final class DashStyleTests: XCTestCase {

    /// From History: every "—" Scribe wrote stood between spaces, and half came before "це".
    private let recorded = [
        "Перевірив у редакторі — все працює чітко. В терміналі",
        "Перше — там, де людина може писати про",
        "І останнє місце — це вже кінець самого",
    ]

    func testTheDashIsRedrawnNeverRemoved() {
        XCTAssertEqual(DashStyle.enDash.applied(to: "Книга — це набір листків"), "Книга – це набір листків")
        XCTAssertEqual(DashStyle.hyphen.applied(to: "Книга — це набір листків"), "Книга - це набір листків")
        XCTAssertEqual(DashStyle.emDash.applied(to: "Книга — це набір листків"), "Книга — це набір листків")
    }

    /// A short dash or a hyphen glued to its words reads as a range or a compound.
    func testAGluedDashIsGivenSpaces() {
        XCTAssertEqual(DashStyle.enDash.applied(to: "word—word"), "word – word")
        XCTAssertEqual(DashStyle.hyphen.applied(to: "— Привіт"), "- Привіт")
        XCTAssertEqual(DashStyle.enDash.applied(to: "текст\n— пункт"), "текст\n– пункт")
    }

    func testHyphensAndRangesAreLeftAlone() {
        let text = "AI-генерація, сторінки 2–5 і 1914-1918"
        for style in DashStyle.allCases {
            XCTAssertEqual(style.applied(to: text), text, style.rawValue)
        }
        XCTAssertEqual(DashStyle.hyphen.applied(to: "Книга – це"), "Книга - це")
    }

    func testRedrawingIsIdempotent() {
        for style in DashStyle.allCases {
            for text in recorded + ["word—word", "Книга—"] {
                let once = style.applied(to: text)
                XCTAssertEqual(style.applied(to: once), once, text)
            }
        }
    }

    /// The same property the hesitation cleanup keeps: text already pasted while the user
    /// spoke must still be a word prefix of the cleaned whole — including a dash that was
    /// the last thing said, glued or not.
    func testEveryWordPrefixRedrawsToAPrefixOfTheWhole() {
        for style in DashStyle.allCases {
            for text in recorded + ["Книга— це набір"] {
                let words = text.split(separator: " ")
                var previous = ""
                for count in 1...words.count {
                    let drawn = style.applied(to: words.prefix(count).joined(separator: " "))
                    XCTAssertTrue(previous.isEmpty || drawn.hasPrefix(previous + " "),
                                  "\(style): \"\(previous)\" is not extended by \"\(drawn)\"")
                    previous = drawn
                }
            }
        }
    }

    /// Its own setting: turning hesitation cleanup off keeps the dash style.
    func testTheConfigurationAppliesItWithOrWithoutCleanup() {
        var configuration = RecordingConfiguration(provider: .elevenlabs, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "", .elevenLabs: "scribe_v2_realtime"])
        XCTAssertEqual(configuration.cleaned("Книга — цеее, е-е, набір"), "Книга – це, набір")
        configuration.removesDisfluencies = false
        XCTAssertEqual(configuration.cleaned("Книга — е-е"), "Книга – е-е")
        configuration.dashStyle = .emDash
        XCTAssertEqual(configuration.cleaned("Книга — е-е"), "Книга — е-е")
    }
}

// MARK: - Characters that disguise themselves (TranscriptCleanup.swift)

final class ConfusablePunctuationTests: XCTestCase {

    func testTheMeasuredSubstitutionIsUndone() {
        // A hosted model returned this for a transcript that had an ASCII hyphen, and
        // nothing on screen told the two apart.
        let fromTheModel = "по\u{2011}перше, будь\u{2011}які"
        XCTAssertEqual(replacingConfusablePunctuation(fromTheModel), "по-перше, будь-які")
    }

    func testACommandSurvivesIntact() {
        let mangled = "git\u{00A0}commit\u{00A0}-m \u{2011}-amend"
        XCTAssertEqual(replacingConfusablePunctuation(mangled), "git commit -m --amend")
    }

    func testInvisibleMarksAreRemoved() {
        XCTAssertEqual(replacingConfusablePunctuation("\u{FEFF}при\u{00AD}віт\u{200B}"), "привіт")
    }

    func testCleanTextIsReturnedUnchanged() {
        let text = "Зустрінемось о 5. Ось список:\n- перше\n- друге"
        XCTAssertEqual(replacingConfusablePunctuation(text), text)
    }

    func testAFamilyEmojiIsNotTakenApart() {
        // U+200D is what holds it together; removing it would leave three people.
        let family = "👨‍👩‍👧 і 🇺🇦"
        XCTAssertEqual(replacingConfusablePunctuation(family), family)
    }

    func testVisibleTypographyIsLeftAlone() {
        // Curly quotes and "…" are ordinary typography the user may well want, and the
        // en and em dashes are `DashStyle`'s business, not this rule's.
        let text = "«Книга» — це “щось”, ти ж знаєш… 2–5 сторінок"
        XCTAssertEqual(replacingConfusablePunctuation(text), text)
    }

    func testNoWordIsJoinedToItsNeighbour() {
        // Every mapping is one scalar to one scalar or to nothing, so a text that had
        // three words still has three.
        let mangled = "одне\u{202F}друге\u{00A0}третє"
        XCTAssertEqual(replacingConfusablePunctuation(mangled).split(separator: " ").count, 3)
    }

    func testTheRefinementPathAppliesItAlongsideTheDashStyle() {
        // Both passes run on an LLM reply: the look-alike hyphen goes back to ASCII and
        // the em dash is still redrawn in the user's style.
        let reply = "по\u{2011}перше — це так"
        let filtered = replacingConfusablePunctuation(reply)
        XCTAssertEqual(DashStyle.enDash.applied(to: filtered), "по-перше – це так")
    }
}

// MARK: - Known hallucinations (HallucinationFilter.swift)

final class HallucinationFilterTests: XCTestCase {

    func testAKnownPhraseThatIsTheWholeResultOfAShortSegmentIsAHallucination() {
        for text in ["Thank you for watching!", "  thanks for watching.", "Evet.", "Seyit.",
                     "Дякую за перегляд!", "Продолжение следует...", "Субтитры сделал DimaTorzok", "Субтитрування DimaTorzok",
                     "Subtitles by the Amara.org community"] {
            XCTAssertTrue(HallucinationFilter.isHallucination(text, segmentSeconds: 1.2), text)
        }
    }

    func testTheSamePhraseInALongerSegmentIsLeftAlone() {
        XCTAssertFalse(HallucinationFilter.isHallucination("Evet.", segmentSeconds: 2.5))
        XCTAssertTrue(HallucinationFilter.isHallucination("Evet.", segmentSeconds: STTTuning.hallucinationSegmentSeconds))
    }

    /// Only the whole result: the words inside a real dictation are speech.
    func testAPhraseInsideADictationIsLeftAlone() {
        for text in ["Evet, bu doğru.", "Thank you for watching the demo yesterday.",
                     "Дякую за перегляд документа", "Субтитрик", "Altyazılar hazır",
                     "Transcription by Friday.", "Субтитры готовы.", "Subtitles by tomorrow, please."] {
            XCTAssertFalse(HallucinationFilter.isHallucination(text, segmentSeconds: 1), text)
        }
    }

    /// Phrases a person plausibly dictates on their own are not on the list.
    func testShortRealRepliesAreNotOnTheList() {
        for text in ["Thank you.", "Дякую за увагу.", "Так.", "Yes.", ""] {
            XCTAssertFalse(HallucinationFilter.isHallucination(text, segmentSeconds: 1), text)
        }
    }

    /// A writer that measured nothing (0 s) leaves the phrase as the only evidence.
    func testAnUnmeasuredSegmentCountsAsShort() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Evet.", segmentSeconds: 0))
    }

    /// #166: «.» and «..» are what a model writes for a breath — at any length.
    func testAResultWithNoLetterOrDigitIsRejected() {
        for text in [".", "..", "…", " ?! ", "— –"] {
            XCTAssertEqual(HallucinationFilter.rejection(text, segmentSeconds: 30, languages: []), .noLettersOrDigits, text)
        }
        for text in ["", "   ", "42", "Так.", "OK"] {
            XCTAssertNil(HallucinationFilter.rejection(text, segmentSeconds: 30, languages: []), text)
        }
    }

    /// The phrase rule keeps its 2 s bound inside the one entry point.
    func testAKnownPhraseIsRejectedOnlyOnAShortSegment() {
        XCTAssertEqual(HallucinationFilter.rejection("Thank you for watching.", segmentSeconds: 1, languages: []), .knownPhrase)
        XCTAssertNil(HallucinationFilter.rejection("Thank you for watching.", segmentSeconds: 15, languages: []))
    }

    /// #166: what the corpus's breath and cough came back as, for someone who speaks
    /// Ukrainian and English.
    func testAResultWhollyInAScriptNoStatedLanguageUsesIsRejected() {
        for text in ["うーん。", "흠..", "음 음 음", "嗯", "مرحبا", "שלום", "สวัสดี", "नमस्ते", "Γεια"] {
            XCTAssertEqual(HallucinationFilter.rejection(text, segmentSeconds: 30, languages: ["uk", "en"]),
                           .foreignScript, text)
        }
    }

    func testAScriptOfAStatedLanguageOrLatinIsKept() {
        let kept: [(String, [String])] = [
            ("Привіт", ["uk"]), ("Docker", ["uk"]), ("OK, 흠", ["uk"]), ("こんにちは", ["ja"]), ("カタカナ", ["ja"]),
            ("漢字", ["ja"]), ("안녕", ["ko"]), ("你好", ["zh"]), ("Ciao", ["it"]), ("Привет", ["ru", "en"]),
            ("Hola", ["xx"]), ("ᚠᚢᚦ", ["uk"]),   // an unknown code judges nothing; an unmapped script is kept
        ]
        for (text, languages) in kept {
            XCTAssertNil(HallucinationFilter.rejection(text, segmentSeconds: 30, languages: languages), text)
        }
        XCTAssertNil(HallucinationFilter.rejection("うーん。", segmentSeconds: 30, languages: []),
                     "with no language stated the script is never judged")
        XCTAssertEqual(HallucinationFilter.rejection("你好", segmentSeconds: 30, languages: ["ko"]), nil,
                       "Korean is written with Han too")
        XCTAssertEqual(HallucinationFilter.rejection("こんにちは", segmentSeconds: 30, languages: ["zh"]), .foreignScript)
    }

    /// Every language a user can state has a script the rule knows, and its own letters
    /// are never taken for a foreign script.
    func testEveryCatalogueLanguageHasAScript() {
        let samples: [WritingScript: String] = [
            .latin: "a", .cyrillic: "ж", .greek: "λ", .arabic: "ب", .hebrew: "ש", .devanagari: "क", .thai: "ก",
            .hangul: "한", .hiragana: "あ", .katakana: "ア", .han: "字",
        ]
        XCTAssertEqual(Set(samples.keys), Set(WritingScript.allCases))
        for (script, letter) in samples {
            XCTAssertEqual(WritingScript.of(letter.unicodeScalars.first!), script, letter)
        }
        for language in spokenLanguageCatalog {
            XCTAssertFalse(language.scripts.isEmpty, language.id)
            for script in language.scripts {
                XCTAssertFalse(HallucinationFilter.isForeignScript(samples[script]!, languages: [language.id]),
                               "\(language.id) \(script)")
            }
        }
    }

    func testNormalisationKeepsWordsAndDropsEverythingElse() {
        XCTAssertEqual(HallucinationFilter.normalized("  Don’t — STOP!! 42 "), "dont stop 42")
        XCTAssertEqual(HallucinationFilter.normalized("Дякую\nза   перегляд…"), "дякую за перегляд")
    }
}
