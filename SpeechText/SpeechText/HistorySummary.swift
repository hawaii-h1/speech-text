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

/// How long something History holds is kept: not at all past this session, a span of
/// days or months, or for good — one scale, as a cache-size slider is, used twice: for the
/// dictations (`SettingsKeys.historyRetention`) and for the audio of a failed one, kept
/// for a retry (`SettingsKeys.failedAudioRetention`).
///
/// *Don't keep* still keeps what this session made until the app quits: the record is
/// what an AI pass attaches to, what the "No connection" notice's Retry and the offline
/// drain read, and where a failed dictation's audio waits for them. It goes at quit, and
/// at the next launch should the app not have quit cleanly.
enum HistoryRetention: String, CaseIterable, Identifiable {
    case session = "none"
    case days7 = "7d"
    case days30 = "30d"
    case months3 = "3m"
    case months6 = "6m"
    case year = "1y"
    case forever

    /// What History keeps on an install that never chose — and on one that chose a number
    /// of dictations, before the choice became a span of time: nothing is deleted by an
    /// update.
    static let `default` = HistoryRetention.forever
    /// What the audio of a failed dictation was always kept for.
    static let defaultAudio = HistoryRetention.days7

    var id: String { rawValue }

    /// A stored value; anything unknown (the old "300" and "1000" included) is `fallback`.
    static func stored(_ raw: String?, default fallback: HistoryRetention = .default) -> HistoryRetention {
        raw.flatMap(HistoryRetention.init(rawValue:)) ?? fallback
    }

    /// The slider's label.
    var title: String {
        switch self {
        case .session: "Don't keep"
        case .days7: "7 days"
        case .days30: "30 days"
        case .months3: "3 months"
        case .months6: "6 months"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }

    /// The end of "History keeps …" / "Counted from …".
    var phrase: String {
        switch self {
        case .session: "this session's dictations"
        case .days7: "the last 7 days of dictations"
        case .days30: "the last 30 days of dictations"
        case .months3: "the last 3 months of dictations"
        case .months6: "the last 6 months of dictations"
        case .year: "the last year of dictations"
        case .forever: "every dictation"
        }
    }

    /// The span, on the calendar; nil for the two that are not one.
    private var span: DateComponents? {
        switch self {
        case .session, .forever: nil
        case .days7: DateComponents(day: 7)
        case .days30: DateComponents(day: 30)
        case .months3: DateComponents(month: 3)
        case .months6: DateComponents(month: 6)
        case .year: DateComponents(year: 1)
        }
    }

    /// The oldest date it keeps; nil keeps everything. `sessionStart` is when this run of
    /// the app began — what *Don't keep* keeps from (`.distantFuture` at quit keeps nothing).
    func cutoff(now: Date = Date(), sessionStart: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .forever: return nil
        case .session: return sessionStart
        default:
            var back = span!
            back.day = back.day.map { -$0 }
            back.month = back.month.map { -$0 }
            back.year = back.year.map { -$0 }
            return calendar.date(byAdding: back, to: now) ?? now
        }
    }

    /// Until when something made at `date` is kept; nil for `forever` and `session`.
    func keptUntil(_ date: Date, calendar: Calendar = .current) -> Date? {
        span.flatMap { calendar.date(byAdding: $0, to: date) }
    }

    /// How many of `records` — newest first — it keeps: the rest are older than it allows.
    func keptCount(of records: [TranscriptionRecord], now: Date = Date(), sessionStart: Date,
                   calendar: Calendar = .current) -> Int {
        guard let cutoff = cutoff(now: now, sessionStart: sessionStart, calendar: calendar) else { return records.count }
        return records.firstIndex { $0.date < cutoff } ?? records.count
    }

    /// Whether audio kept this long is ever kept longer than History keeps its dictation —
    /// the audio goes with the record, so the shorter of the two is what counts.
    func outlasts(_ other: HistoryRetention) -> Bool {
        guard let mine = Self.allCases.firstIndex(of: self),
              let theirs = Self.allCases.firstIndex(of: other) else { return false }
        return mine > theirs
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

    /// How long a failed dictation's audio is kept for a retry, as the end of "The audio is
    /// kept …": "until Thursday 8 October", "until SpeechText quits". The shorter of the two
    /// settings decides, since the audio goes with its record.
    static func audioKept(_ record: TranscriptionRecord, audio: HistoryRetention, history: HistoryRetention,
                          calendar: Calendar = .current) -> String {
        let rule = audio.outlasts(history) ? history : audio
        if rule == .session { return "until SpeechText quits" }
        guard let until = rule.keptUntil(record.date, calendar: calendar) else { return "for as long as History keeps it" }
        return "until " + formatter("EEEE d MMMM", calendar: calendar).string(from: until)
    }

    /// What History holds now, under its settings: "125 dictations since 14 September · 70 KB".
    static func storageSummary(count: Int, since: Date?, bytes: Int64, calendar: Calendar = .current) -> String {
        guard count > 0 else { return "No dictations kept yet." }
        let dictations = count == 1 ? "1 dictation" : "\(HomeFormat.integer(count)) dictations"
        let start = since.map { " since " + formatter("d MMMM", calendar: calendar).string(from: $0) } ?? ""
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return dictations + start + " · " + size
    }

    /// What History keeps, in a sentence or two — History's foot.
    static func retentionSummary(history: HistoryRetention, audio: HistoryRetention) -> String {
        let kept = history == .session
            ? "History keeps this session's dictations, until SpeechText quits."
            : "History keeps \(history.phrase) on this Mac."
        let rule = audio.outlasts(history) ? history : audio
        let audioKept: String = switch rule {
        case .session: "until SpeechText quits"
        case .forever: "as long as the dictation"
        case .year: "for a year"
        default: "for " + rule.title
        }
        return kept + " A failed one's audio is kept \(audioKept), for a retry."
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
