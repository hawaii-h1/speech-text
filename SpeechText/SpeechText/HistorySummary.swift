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

// MARK: - App and date

/// The day range History is narrowed to, beside the search and the filters.
enum HistoryDates: Equatable, Hashable {
    case anyTime, today, last7Days, last30Days
    /// One day the user picked.
    case day(Date)

    static let presets: [HistoryDates] = [.anyTime, .today, .last7Days, .last30Days]

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .day(let day): HistoryFormat.formatter("d MMM yyyy", calendar: .current).string(from: day)
        }
    }

    func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        func since(_ days: Int) -> Bool {
            date >= (calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today)
        }
        switch self {
        case .anyTime: return true
        case .today: return since(1)
        case .last7Days: return since(7)
        case .last30Days: return since(30)
        case .day(let day): return calendar.isDate(date, inSameDayAs: day)
        }
    }
}

/// What History is narrowed to besides the filter and the search: the app a dictation went
/// to — named as its row names it (`HomeRecentEntry.place`, so "Record Window" and "Not
/// pasted" are there too) — and a range of days.
struct HistoryNarrowing: Equatable {
    var app: String?
    var dates: HistoryDates = .anyTime

    var isEmpty: Bool { app == nil && dates == .anyTime }

    func includes(_ record: TranscriptionRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if let app, HomeRecentEntry(record).place != app { return false }
        return dates.includes(record.date, now: now, calendar: calendar)
    }

    /// Every place dictations went, the busiest first, with how many went there.
    static func apps(in records: [TranscriptionRecord]) -> [(app: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in records { counts[HomeRecentEntry(record).place, default: 0] += 1 }
        return counts.map { (app: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.app.localizedCompare($1.app) == .orderedAscending }
    }
}

// MARK: - How long History keeps dictations

/// How much History keeps: a number of the latest dictations, the ones from a span of
/// time, or all of them — a single choice as Messages' "Keep messages" is. The audio of a
/// failed dictation is kept a week whatever this says (`TranscriptionHistory.audioRetention`).
enum HistoryRetention: String, CaseIterable, Identifiable {
    case last300 = "300"
    case last1000 = "1000"
    case days30 = "30d"
    case year = "1y"
    case forever

    /// What History always kept before the choice existed.
    static let `default` = HistoryRetention.last300

    var id: String { rawValue }

    /// A stored value; anything unknown is the default.
    static func stored(_ raw: String?) -> HistoryRetention {
        raw.flatMap(HistoryRetention.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .last300: "300 dictations"
        case .last1000: "1,000 dictations"
        case .days30: "30 days"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }

    /// The end of "History keeps …".
    var phrase: String {
        switch self {
        case .last300: "your last 300 dictations"
        case .last1000: "your last 1,000 dictations"
        case .days30: "the last 30 days of dictations"
        case .year: "the last year of dictations"
        case .forever: "every dictation"
        }
    }

    /// How many of `records` — newest first — it keeps: the rest are older than it allows.
    func keptCount(of records: [TranscriptionRecord], now: Date = Date(), calendar: Calendar = .current) -> Int {
        switch self {
        case .last300: return min(records.count, 300)
        case .last1000: return min(records.count, 1000)
        case .forever: return records.count
        case .days30, .year:
            let cutoff = calendar.date(byAdding: self == .days30 ? .day : .year, value: self == .days30 ? -30 : -1,
                                       to: now) ?? now
            return records.firstIndex { $0.date < cutoff } ?? records.count
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

    /// The records that pass `filter`, `query` and `narrowing`, one day each, newest day
    /// first. History is kept newest first, and so is each day.
    static func group(_ records: [TranscriptionRecord], filter: HistoryFilter = .all, query: String = "",
                      narrowing: HistoryNarrowing = HistoryNarrowing(), now: Date = Date(),
                      calendar: Calendar = .current) -> [HistoryDay] {
        var days: [HistoryDay] = []
        var current: (start: Date, records: [TranscriptionRecord])?
        for record in records where filter.includes(record) && HistorySearch.matches(record, query: query)
            && narrowing.includes(record, now: now, calendar: calendar) {
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
    /// Made once per format and calendar: a `DateFormatter` is costly to build, and every
    /// History row asks for its clock each time it is drawn.
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let key = "\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let known = formatters[key] { return known }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
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
