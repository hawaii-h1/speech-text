// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Terms to the engine

/// A term from the Settings › Speech › Vocabulary list #121 shipped, before the
/// Dictionary (`Vocabulary`) became the one store. Decoded only by
/// `CustomVocabulary.migrateLegacyStoreIfNeeded`, which moves the list into the
/// Dictionary once.
struct VocabularyTerm: Codable, Hashable, Identifiable {
    var id: UUID
    var text: String
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

/// Which of the Dictionary's words a speech model is sent, and in what order. The words
/// are `Vocabulary`'s; this decides only what reaches an engine through a parameter that
/// is a term list (`STTModelDescriptor.vocabulary`). Pure logic, in both targets; its
/// only reader of History is `historyTexts`, which the app points at
/// `TranscriptionHistory` at launch.
enum CustomVocabulary {
    /// Words added this recently go first when a model cannot take them all.
    static let recentDays: Double = 7

    /// The longest term sent to an engine with no limit of its own: Scribe's upload takes
    /// under 50 characters, and no engine here is sent longer.
    static let maxEntryCharacters = 49

    /// Replaced at launch by the texts of the History records, newest first. Empty
    /// until then, which is the test bundle's state: nothing is ranked by use there.
    nonisolated(unsafe) static var historyTexts: () -> [String] = { [] }

    /// Whether the Dictionary's words are sent to the speech engine — the one switch, on
    /// the Dictionary page. On unless the user turned it off.
    static func isSent(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKeys.sendVocabularyToEngine) as? Bool ?? true
    }

    static func wordCount(_ term: String) -> Int {
        term.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: The list #121 shipped

    /// `entries` with every legacy term it does not already hold (ignoring case) added as
    /// a word of its own, with the date it was added.
    static func migrateLegacyTerms(_ legacy: [VocabularyTerm], into entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var known = Set(entries.map { $0.trimmedTerm.lowercased() })
        var merged = entries
        for term in legacy {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, known.insert(text.lowercased()).inserted else { continue }
            merged.append(VocabularyEntry(id: term.id, term: text, added: term.added))
        }
        return merged
    }

    /// Moves a stored `customVocabulary` into the Dictionary once, then deletes it. Writes
    /// nothing when there is nothing stored: a stored setting is evidence of an earlier
    /// install to `OnboardingGate` (this runs after it has decided, but a new install has
    /// no reason to gain a key).
    static func migrateLegacyStoreIfNeeded(_ defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: SettingsKeys.customVocabulary) else { return }
        let legacy = (try? JSONDecoder().decode([VocabularyTerm].self, from: data)) ?? []
        if !legacy.isEmpty {
            let entries = Vocabulary.decode(defaults.data(forKey: SettingsKeys.vocabulary))
            defaults.set(Vocabulary.encode(migrateLegacyTerms(legacy, into: entries)),
                         forKey: SettingsKeys.vocabulary)
        }
        defaults.removeObject(forKey: SettingsKeys.customVocabulary)
        dlog("Settings", "moved \(legacy.count) Speech vocabulary term(s) into the Dictionary")
    }

    // MARK: Selection

    /// The Dictionary's words in the order they are sent: those added in the last
    /// `recentDays` newest first, then the rest by how many History records use them
    /// (whole words, ignoring case), ties going to the newer word. A blank word, and a
    /// second spelling of one already listed (ignoring case), are left out. `historyTexts`
    /// is read only when `rankByUse` — the order matters only when some engine cannot
    /// take them all.
    static func ranked(_ entries: [VocabularyEntry], now: Date, rankByUse: Bool,
                       historyTexts: () -> [String]) -> [String] {
        var seen = Set<String>()
        let terms = entries.filter { !$0.trimmedTerm.isEmpty && seen.insert($0.trimmedTerm.lowercased()).inserted }
        let cutoff = now.addingTimeInterval(-recentDays * 86_400)
        let recent = terms.filter { $0.added > cutoff }.sorted { $0.added > $1.added }
        var older = terms.filter { $0.added <= cutoff }.sorted { $0.added > $1.added }
        if rankByUse, older.count > 1 {
            let texts = historyTexts().map { " " + words($0) + " " }
            let uses = Dictionary(older.map { entry -> (UUID, Int) in
                let needle = " " + words(entry.trimmedTerm) + " "
                guard needle.count > 2 else { return (entry.id, 0) }
                return (entry.id, texts.reduce(0) { $0 + occurrences(of: needle, in: $1) })
            }, uniquingKeysWith: { first, _ in first })
            // Stable on the date order above, so ties keep the newer word first.
            older = older.enumerated().sorted { lhs, rhs in
                let (a, b) = (uses[lhs.element.id] ?? 0, uses[rhs.element.id] ?? 0)
                return a != b ? a > b : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return (recent + older).map(\.trimmedTerm)
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
