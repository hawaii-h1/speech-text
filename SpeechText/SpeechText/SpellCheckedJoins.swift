// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// Apart from App.swift so the corpus runs (`LiveProviderTests`, `SpeechTextEvaluation`)
// register the same word check the app registers at launch: without it no word a provider
// cut in two is ever glued back, and the clip that tests it measures nothing.

/// Points `TranscriptJoin.isWord` at the macOS spell checker, so a segment boundary the
/// provider cut mid-word can be glued back. The language follows the script: the English
/// checker waves every Cyrillic word through, so it would call any fragment a word.
func registerSpellCheckedJoins() {
    let lock = NSLock()
    let uk = NSSpellChecker.shared.availableLanguages.contains("uk")
    TranscriptJoin.isWord = { word in
        let latin = word.unicodeScalars.allSatisfy { $0.isASCII }
        let cyrillic = word.unicodeScalars.allSatisfy { ("\u{0400}"..."\u{04FF}").contains($0) || $0 == "'" || $0 == "’" }
        let language: String
        if latin { language = "en" } else if cyrillic, uk { language = "uk" } else { return false }
        lock.lock(); defer { lock.unlock() }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
    dlog("App", "segment joins: spell checker registered (uk \(uk ? "available" : "missing"))")
}
