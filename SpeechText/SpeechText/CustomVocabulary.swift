// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Custom vocabulary

/// One word or name the user wants a speech model to expect — a product, a colleague, a
/// piece of jargon. Stored as typed: the case is part of the term ("iOS", "SpeechText").
struct VocabularyTerm: Codable, Hashable, Identifiable {
    var id: UUID
    var text: String
    /// When the term was added. A term added in the last `CustomVocabulary.recentDays`
    /// is sent ahead of the rest: it is new because the engine keeps getting it wrong,
    /// and History cannot have seen it spelled right yet.
    var added: Date

    init(id: UUID = UUID(), text: String, added: Date = Date()) {
        self.id = id
        self.text = text
        self.added = added
    }
}

/// How many terms a model takes, and what shape each must have. Every limit is the
/// vendor's documented one unless its comment in the catalogue says it is ours.
struct TermListLimits: Hashable {
    let maxTerms: Int
    /// Inclusive.
    let maxCharacters: Int
    /// Inclusive; nil when the vendor sets none.
    let maxWords: Int?
    /// Characters the vendor refuses the *whole request* for — so a term holding one is
    /// skipped rather than sent.
    let forbidden: Set<Character>

    func accepts(_ term: String) -> Bool {
        guard !term.isEmpty, term.count <= maxCharacters else { return false }
        if term.contains(where: { forbidden.contains($0) || $0.isNewline }) { return false }
        if let maxWords, CustomVocabulary.wordCount(term) > maxWords { return false }
        return true
    }
}

/// The user's vocabulary: what may be stored, and which of it a given model is sent.
/// Pure logic, in both targets; the store's only reader of History is `historyTexts`,
/// which the app points at `TranscriptionHistory` at launch.
enum CustomVocabulary {
    /// Terms added this recently go first when a model cannot take them all.
    static let recentDays: Double = 7

    /// The longest term the page accepts: Scribe's upload takes under 50 characters,
    /// and every other engine here as many or more. Scribe's realtime socket takes only
    /// 20; a longer term simply is not sent there.
    static let maxEntryCharacters = 49
    /// Scribe's limit, the only vendor that states one.
    static let maxEntryWords = 5
    /// Every character any engine refuses a whole request for: OpenAI's `<` `>`, and
    /// Scribe's `<` `>` `{` `}` `[` `]` `\`. Line breaks are refused by construction —
    /// `normalizedEntry` folds all whitespace into single spaces.
    static let forbiddenEntryCharacters: Set<Character> = ["<", ">", "{", "}", "[", "]", "\\"]

    /// Replaced at launch by the texts of the History records, newest first. Empty
    /// until then, which is the test bundle's state: nothing is ranked by use there.
    nonisolated(unsafe) static var historyTexts: () -> [String] = { [] }

    // MARK: Entry

    /// The term as it would be stored: trimmed, with every run of whitespace — a line
    /// break included — as one space.
    static func normalizedEntry(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    enum EntryProblem: Equatable {
        case empty
        case tooLong
        case tooManyWords
        case forbiddenCharacter(Character)
        case duplicate
    }

    /// Why `text` cannot be added to `existing`, or nil when it can. Checked against the
    /// strictest engine, so a stored term is one at least one engine can take whole.
    static func entryProblem(_ text: String, existing: [VocabularyTerm]) -> EntryProblem? {
        let term = normalizedEntry(text)
        if term.isEmpty { return .empty }
        if let bad = term.first(where: { forbiddenEntryCharacters.contains($0) }) {
            return .forbiddenCharacter(bad)
        }
        if term.count > maxEntryCharacters { return .tooLong }
        if wordCount(term) > maxEntryWords { return .tooManyWords }
        if existing.contains(where: { $0.text.caseInsensitiveCompare(term) == .orderedSame }) {
            return .duplicate
        }
        return nil
    }

    static func wordCount(_ term: String) -> Int {
        term.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: Storage

    static func decode(_ data: Data?) -> [VocabularyTerm] {
        guard let data, let terms = try? JSONDecoder().decode([VocabularyTerm].self, from: data) else {
            return []
        }
        return terms
    }

    static func encode(_ terms: [VocabularyTerm]) -> Data? {
        try? JSONEncoder().encode(terms)
    }

    /// The stored vocabulary. Never written except by the Settings page: a stored value
    /// is evidence of an earlier install to `OnboardingGate`.
    static func stored(_ defaults: UserDefaults = .standard) -> [VocabularyTerm] {
        decode(defaults.data(forKey: SettingsKeys.customVocabulary))
    }

    static func save(_ terms: [VocabularyTerm], _ defaults: UserDefaults = .standard) {
        guard let data = encode(terms) else { return }
        defaults.set(data, forKey: SettingsKeys.customVocabulary)
    }

    /// Whether the switch is on. On unless the user turned it off: the vocabulary starts
    /// empty, so the default sends nothing until there is something to send.
    static func isSent(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKeys.sendVocabularyToEngine) as? Bool ?? true
    }

    // MARK: Selection

    /// The terms in the order they are sent: those added in the last `recentDays`
    /// newest first, then the rest by how many History records use them (whole words,
    /// ignoring case), ties going to the newer term. `historyTexts` is only read when
    /// `rankByUse` — the ranking matters only when some model cannot take them all.
    static func ranked(_ terms: [VocabularyTerm], now: Date, rankByUse: Bool,
                       historyTexts: () -> [String]) -> [String] {
        let cutoff = now.addingTimeInterval(-recentDays * 86_400)
        let recent = terms.filter { $0.added > cutoff }.sorted { $0.added > $1.added }
        var older = terms.filter { $0.added <= cutoff }.sorted { $0.added > $1.added }
        if rankByUse, older.count > 1 {
            let texts = historyTexts().map { " " + words($0) + " " }
            let uses = Dictionary(older.map { term -> (UUID, Int) in
                let needle = " " + words(term.text) + " "
                guard needle.count > 2 else { return (term.id, 0) }
                return (term.id, texts.reduce(0) { $0 + occurrences(of: needle, in: $1) })
            }, uniquingKeysWith: { first, _ in first })
            // Stable on the date order above, so ties keep the newer term first.
            older = older.enumerated().sorted { lhs, rhs in
                let (a, b) = (uses[lhs.element.id] ?? 0, uses[rhs.element.id] ?? 0)
                return a != b ? a > b : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return (recent + older).map(\.text)
    }

    /// What a model with `limits` is sent from the `ranked` list: every term it accepts,
    /// in order, up to its count. A term it would refuse is skipped, never cut short —
    /// half a name is a different name. Nil limits send nothing.
    static func selected(_ ranked: [String], limits: TermListLimits?) -> [String] {
        guard let limits else { return [] }
        return Array(ranked.lazy.filter { limits.accepts($0) }.prefix(limits.maxTerms))
    }

    /// Lowercased words of letters and digits, one space apart — the same text a term
    /// is looked for in, so "AC-42" finds "ac-42," and "API" does not find "rapid".
    static func words(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .joined(separator: " ")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            // Step back over the shared space so "a a" counts twice in " a a ".
            searchRange = haystack.index(before: found.upperBound)..<haystack.endIndex
        }
        return count
    }
}
