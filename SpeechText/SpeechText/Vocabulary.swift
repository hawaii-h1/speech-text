// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The main window's Dictionary: the words a dictation keeps getting wrong — names, product
// terms, code identifiers — and how they are spelled. The field calls this a *custom
// vocabulary*; Apple's Speech framework, *contextual strings*; the UI says Dictionary,
// which is the design's name for the page. (`Dictionary` itself is Swift's, hence
// `Vocabulary` here.)
//
// Each word does three things, as far as each step allows:
// - the speech engine is told it, where its API takes a hint — Apple's recogniser
//   (`contextualStrings`) and Groq's Whisper (`prompt`). ElevenLabs charges 20% more for
//   its key terms and OpenAI's newer models do not document a prompt, so those are not;
// - the wrong spellings the user lists are replaced in what comes back, whatever the
//   engine — `corrected`;
// - AI Rewrite is handed the words and told to keep them as written — `promptBlock`.
//
// Pure, in both targets. The page is DictionaryView.swift.

/// One word the user taught: how it is spelled, and how it has come out wrong.
struct VocabularyEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var term: String
    /// Spellings that are replaced by `term` — what the engine wrote instead.
    var misheard: [String]
    var added: Date

    init(id: UUID = UUID(), term: String, misheard: [String] = [], added: Date = Date()) {
        self.id = id
        self.term = term
        self.misheard = misheard
        self.added = added
    }

    var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The listed spellings, trimmed, without blanks or the term itself.
    var replacements: [String] {
        var seen = Set<String>()
        return misheard
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != trimmedTerm && seen.insert($0.lowercased()).inserted }
    }

    /// A word whose capitals are the point — "iPhone", "SpeechText", "JSON", "macOS" — is
    /// put back the way it is written when it comes out in other capitals, even with no
    /// wrong spelling listed. A plain word or a name ("Olena", "Apple") is not: lower case
    /// may be another word, and a capital may only be the start of a sentence.
    var fixesCapitals: Bool {
        let letters = trimmedTerm.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let rest = letters.dropFirst()
        return rest.contains(where: \.isUppercase)
    }
}

enum Vocabulary {
    // MARK: Replacing

    /// `text` with every listed wrong spelling replaced by its word: whole words only,
    /// ignoring case, the longest spelling first; a spelling of several words matches
    /// across any run of spaces. Replacing a word that is already right changes nothing,
    /// so running this twice is the same as running it once.
    static func corrected(_ text: String, entries: [VocabularyEntry]) -> String {
        guard !text.isEmpty else { return text }
        var pairs: [(wrong: String, right: String)] = []
        for entry in entries {
            let term = entry.trimmedTerm
            guard !term.isEmpty else { continue }
            pairs += entry.replacements.map { ($0, term) }
            if entry.fixesCapitals { pairs.append((term, term)) }
        }
        guard !pairs.isEmpty else { return text }
        pairs.sort { $0.wrong.count > $1.wrong.count }

        var result = text
        for (wrong, right) in pairs {
            let words = wrong.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}_])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: right))
        }
        return result
    }

    // MARK: Telling the speech engine

    /// The words for a recogniser that takes a list — Apple's `contextualStrings`, which
    /// Apple advises keeping to about a hundred.
    static func hints(_ entries: [VocabularyEntry], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        return Array(entries.map(\.trimmedTerm).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(limit))
    }

    /// The longest prompt `whisperPrompt` writes. Groq's Whisper reads at most 224 tokens
    /// of prompt and refuses more; Cyrillic runs to a token every two or three characters,
    /// so 300 characters stays well inside it whatever the words.
    static let whisperPromptLimit = 300

    /// Whisper's `prompt` is read as the text before the recording, so the words go in as
    /// a plain list — enough for it to spell them that way when it hears them. Nil when
    /// there are none; words past the limit are left out whole, never cut.
    static func whisperPrompt(_ entries: [VocabularyEntry]) -> String? {
        var prompt = ""
        for term in hints(entries) {
            let next = prompt.isEmpty ? term : prompt + ", " + term
            guard next.count + 1 <= whisperPromptLimit else { break }
            prompt = next
        }
        return prompt.isEmpty ? nil : prompt + "."
    }

    // MARK: Telling AI Rewrite

    /// The `<vocabulary>` block a dictation's user message carries: one word a line, made
    /// unable to close the block. Data, like `<context>` — the system prompt says what to
    /// do with it.
    static func promptBlock(_ entries: [VocabularyEntry]) -> String? {
        let terms = hints(entries).map {
            $0.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
                .replacingOccurrences(of: "\n", with: " ")
        }
        guard !terms.isEmpty else { return nil }
        return "<vocabulary>\n" + terms.joined(separator: "\n") + "\n</vocabulary>"
    }

    // MARK: What History says

    /// How many of `texts` use the word, as written — the page's "in 12 dictations".
    static func uses(of entry: VocabularyEntry, in texts: [String]) -> Int {
        let term = entry.trimmedTerm
        guard !term.isEmpty else { return 0 }
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return texts.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.count
    }

    /// Words from the user's own dictations that look like names or terms — capitals
    /// inside a word ("iPhone", "SpeechText", "JSON"), or a capital that does not start a
    /// sentence or a line ("Olena", "Figma") and is never written in lower case — used at
    /// least `minimumCount` times and not taught yet, most used first.
    static func suggestions(from texts: [String], excluding entries: [VocabularyEntry],
                            minimumCount: Int = 2, limit: Int = 8) -> [(term: String, count: Int)] {
        let known = Set(entries.map { $0.trimmedTerm.lowercased() })
        var counts: [String: Int] = [:]
        var named = Set<String>()
        var lowercase = Set<String>()
        var order: [String] = []

        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) {
                // Each line starts a sentence: a list item, a paragraph.
                var sentenceStart = true
                var seenHere = Set<String>()
                for raw in line.split(whereSeparator: \.isWhitespace) {
                    let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                    let letters = word.filter(\.isLetter)
                    // A bullet or a dash between words leaves the sentence where it was.
                    guard !letters.isEmpty else { continue }
                    defer { sentenceStart = raw.last.map { ".!?…:".contains($0) } ?? false }
                    if letters.allSatisfy(\.isLowercase) { lowercase.insert(word.lowercased()); continue }
                    guard letters.count >= 2,
                          word.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }),
                          !known.contains(word.lowercased()), seenHere.insert(word).inserted else { continue }
                    // A capital inside the word makes it a term wherever it stands; a capital
                    // only at the front counts in the middle of a sentence, never at its start,
                    // where every word wears one.
                    guard letters.dropFirst().contains(where: \.isUppercase) || !sentenceStart else { continue }
                    named.insert(word)
                    if counts[word] == nil { order.append(word) }
                    counts[word, default: 0] += 1
                }
            }
        }
        // A word also written in lower case is an ordinary word that happened to take a
        // capital — "Коли", "All" — not a name.
        named = named.filter { !lowercase.contains($0.lowercased()) }
        // Most used first; a tie keeps the order the words were first said in.
        let found = order.enumerated().compactMap { index, word -> (term: String, count: Int, index: Int)? in
            guard named.contains(word), let count = counts[word], count >= minimumCount else { return nil }
            return (word, count, index)
        }
        return found.sorted { ($1.count, $0.index) < ($0.count, $1.index) }
            .prefix(limit)
            .map { ($0.term, $0.count) }
    }

    // MARK: Storage

    static func decode(_ data: Data?) -> [VocabularyEntry] {
        guard let data, let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data) else { return [] }
        return entries
    }

    static func encode(_ entries: [VocabularyEntry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// The user's words, as stored. Read once per recording by `RecordingConfiguration`
    /// and once per rewrite, never by the tests.
    static func load() -> [VocabularyEntry] {
        decode(UserDefaults.standard.data(forKey: SettingsKeys.vocabulary))
    }

    static func save(_ entries: [VocabularyEntry]) {
        UserDefaults.standard.set(encode(entries), forKey: SettingsKeys.vocabulary)
    }
}
