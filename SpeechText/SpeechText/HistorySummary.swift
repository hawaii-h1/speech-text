// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What the main window's History page shows, worked out from the records — pure, so the
// grouping, the search and the filters are testable without a window. The page itself is
// HistoryView.swift.

// MARK: - Filters

/// The page's filters: every dictation, the ones AI Rewrite rewrote, the edits of a
/// selection, and the ones that did not come out as asked.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, rewritten, edits, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .rewritten: "AI Rewrite"
        case .edits: "Edits"
        case .failed: "Failed"
        }
    }

    func includes(_ record: TranscriptionRecord) -> Bool {
        let edit = record.refinement?.isSelectionEdit == true
        switch self {
        case .all: return true
        case .rewritten: return record.refinement != nil && !edit
        case .edits: return edit
        // Nothing transcribed, nothing heard, or a rewrite that fell back to the dictated
        // text: each pasted something other than what was asked for, or nothing.
        case .failed: return record.status != .success || record.refinement?.succeeded == false
        }
    }
}

// MARK: - Search

enum HistorySearch {
    /// Every word of the query is somewhere in the record — what was said, what was pasted,
    /// the selection an edit rewrote, the error, the apps or the prompt — ignoring case and
    /// accents.
    static func matches(_ record: TranscriptionRecord, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields: [String?] = [
            record.text, record.errorMessage, record.originApp, record.destinationApp,
            record.refinement?.inputText, record.refinement?.outputText,
            record.refinement?.presetName, record.refinement?.context?.appName,
        ]
        let haystack = fields.compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

// MARK: - Days

/// One day of History: its records newest first, and what they came to.
struct HistoryDay: Identifiable, Equatable {
    let start: Date
    let records: [TranscriptionRecord]

    var id: Date { start }

    /// Words that ended up as text, counted as Home's week counts them.
    var words: Int {
        records.reduce(0) { total, record in
            guard record.status == .success, record.refinement?.isSelectionEdit != true else { return total }
            return total + homeWordCount(record.deliveredText)
        }
    }

    /// The records that pass `filter` and `query`, one day each, newest day first. History
    /// is kept newest first, and so is each day.
    static func group(_ records: [TranscriptionRecord], filter: HistoryFilter = .all, query: String = "",
                      calendar: Calendar = .current) -> [HistoryDay] {
        var days: [HistoryDay] = []
        var current: (start: Date, records: [TranscriptionRecord])?
        for record in records where filter.includes(record) && HistorySearch.matches(record, query: query) {
            let start = calendar.startOfDay(for: record.date)
            if current?.start == start {
                current?.records.append(record)
            } else {
                if let current { days.append(HistoryDay(start: current.start, records: current.records)) }
                current = (start, [record])
            }
        }
        if let current { days.append(HistoryDay(start: current.start, records: current.records)) }
        return days
    }

    /// "Today", "Yesterday", a weekday within the week, then "28 September" — with the year
    /// once it is not this one.
    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let format = days > 1 && days < 7 ? "EEEE" : sameYear ? "d MMMM" : "d MMMM yyyy"
        return HistoryFormat.formatter(format, calendar: calendar).string(from: start)
    }

    /// The date under a title that does not already say it: "Monday" → "28 September".
    func subtitle(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0
        guard days < 7 else { return nil }
        return HistoryFormat.formatter(days < 2 ? "EEEE, d MMMM" : "d MMMM", calendar: calendar).string(from: start)
    }
}

// MARK: - Formatting

enum HistoryFormat {
    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "14:02" — a row's day is its section's.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    /// "Wednesday 30 September 2026, 14:02".
    static func full(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("EEEE d MMMM yyyy, HH:mm", calendar: calendar).string(from: date)
    }

    /// "8 s", "1:05".
    static func length(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = max(1, Int(seconds.rounded()))
        return total < 60 ? "\(total) s" : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Until when a failed dictation's audio is kept for a retry: "Thursday 8 October".
    static func audioKeptUntil(_ record: TranscriptionRecord, calendar: Calendar = .current) -> String {
        let until = record.date.addingTimeInterval(TranscriptionHistory.audioRetention)
        return formatter("EEEE d MMMM", calendar: calendar).string(from: until)
    }

    /// The speech engine a record names, as a person would: "Groq", "On this Mac".
    static func engine(_ provider: String) -> String {
        switch STTProviderType(rawValue: provider) {
        case .apple: "Apple"
        case .local: "On this Mac"
        case .some(let type): type.vendor.displayName
        case nil: provider
        }
    }

    /// The language a record was dictated in, by name; nil when the model chose.
    static func language(_ locale: String?) -> String? {
        guard let locale, locale != autoLanguageID, !locale.isEmpty else { return nil }
        let code = String(locale.prefix { $0 != "-" && $0 != "_" })
        return spokenLanguageCatalog.first { $0.id == code }?.displayName ?? locale
    }
}
