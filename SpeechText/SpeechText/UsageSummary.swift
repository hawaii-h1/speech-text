// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SpeechTextCore

// What the main window's Usage page says, worked out from History — pure, so the numbers,
// the chart's buckets and the breakdowns are testable without a window. Counted as Home's
// week counts (`HomeWeek`): words that ended up as text, time saved against typing, and
// the providers' list prices (`UsagePrices`) for what they price, as an estimate — an AI
// pass at the tokens its provider reported, estimated from its words only when it
// predates them (`ChatRates.cost(of:)`). History keeps what `HistoryRetention` lets it, so
// "All" is what it holds. The page is UsageView.swift.

/// The page's periods.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case week, month, quarter, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .all: "All"
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }
}

struct UsageSummary: Equatable {
    /// One bar of the chart: a day, a week or a month.
    struct Bucket: Equatable, Identifiable {
        let start: Date
        /// Words pasted as dictated, and words AI Rewrite wrote.
        var dictatedWords = 0
        var rewrittenWords = 0
        var speechCost: Double = 0
        var aiCost: Double = 0

        var id: Date { start }
        var words: Int { dictatedWords + rewrittenWords }
        var cost: Double { speechCost + aiCost }
    }

    enum Granularity: Equatable { case day, week, month }

    /// What a dictation was: said and pasted, rewritten by AI Rewrite, or an edit of a
    /// selection. History does not record which shortcut started it, so the Record
    /// Window's dictations count as what they became.
    enum Kind: String, CaseIterable, Identifiable {
        case dictated, rewritten, edit

        var id: String { rawValue }
    }

    struct KindUse: Equatable {
        var count = 0
        var words = 0
        var speechCost: Double = 0
        var aiCost: Double = 0
        var cost: Double { speechCost + aiCost }
    }

    /// One model that did the work: a speech model, or an AI Rewrite model — each model
    /// apart, so a user who changes models sees every one they used.
    struct EngineUse: Equatable, Identifiable {
        enum Step: Equatable { case speech, ai }
        let step: Step
        /// The speech provider's raw value, or the chat model's ID.
        let key: String
        /// The chat provider's raw value for an AI Rewrite model; the speech model's ID for
        /// a speech one, nil for records written before History kept it.
        var provider: String?
        var uses = 0
        /// Of an AI Rewrite model's `uses`, the selections it edited (the Edit shortcut);
        /// the rest were dictations it rewrote.
        var edits = 0
        var minutes: Double = 0
        /// Nil when the model has no list price (`ListPrice.notPriced`).
        var cost: Double? = 0
        var isLocal = false

        var id: String { "\(step)-\(key)-\(provider ?? "")" }
    }

    /// One vendor's model as its own replies count it: the requests the ledger holds
    /// (`UsageEvent`), what was sent and billed, and how long an answer took.
    struct RequestUse: Equatable, Identifiable {
        let step: EngineUse.Step
        let vendor: Provider
        let model: String
        var requests = 0
        var failed = 0
        /// Audio sent, and billed where the vendor or its documented minimum said.
        var audioSeconds: Double = 0
        var billedSeconds: Double = 0
        /// Requests whose billed seconds are known; the rest count only as sent.
        var billedRequests = 0
        var inputTokens = 0
        var outputTokens = 0
        var latencies: [Double] = []

        var id: String { "\(step)-\(vendor.rawValue)-\(model)" }

        /// The middle answer time, so one slow request does not speak for the rest.
        var typicalLatency: Double? {
            guard !latencies.isEmpty else { return nil }
            let sorted = latencies.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
    }

    /// What was paid for without becoming the text, and what was never sent at all.
    struct Overhead: Equatable {
        /// Audio streamed for a segment that the upload then transcribed again.
        var paidTwiceSeconds: Double = 0
        var retries = 0
        var retrySeconds: Double = 0
        /// Requests a vendor refused, or that broke off.
        var failedRequests = 0
        /// Silent segments a cloud engine was never sent.
        var notSentSeconds: Double = 0

        var isEmpty: Bool { self == Overhead() }
    }

    struct AppUse: Equatable, Identifiable {
        let app: String
        var words = 0
        var dictations = 0
        var id: String { app }
    }

    var words = 0
    var dictations = 0
    var rewrites = 0
    var edits = 0
    var failed = 0
    /// Minutes of speech behind `words` — first word to last, where the record kept it
    /// (`TranscriptionRecord.speakingDuration`), else the whole recording.
    var speakingMinutes: Double = 0
    /// The words said in those minutes: the transcript, before AI Rewrite made it longer,
    /// shorter or another language. `words` is what was delivered.
    var spokenWords = 0
    var savedMinutes: Double = 0
    var speechCost: Double = 0
    var aiCost: Double = 0
    var unpricedModels: [String] = []
    /// AI passes priced from their words, not their tokens: written before the provider's
    /// usage was kept.
    var estimatedAIPasses = 0
    var buckets: [Bucket] = []
    /// Requests by model, from the ledger — speech first, then the busiest.
    var requests: [RequestUse] = []
    var overhead = Overhead()
    /// The oldest record in the period with a ledger; requests before it were not kept.
    var ledgerSince: Date?
    var granularity: Granularity = .day
    var kinds: [Kind: KindUse] = [:]
    var engines: [EngineUse] = []
    var apps: [AppUse] = []
    /// The oldest dictation History still holds.
    var since: Date?
    /// The day the chart starts on when History begins inside the period — nil when the
    /// chart covers the whole period.
    var chartSince: Date?
    let typingWordsPerMinute: Double

    var spent: Double { speechCost + aiCost }

    /// Words a minute while speaking; nil before there is a minute's worth to divide.
    var speakingWordsPerMinute: Double? {
        guard speakingMinutes >= 0.5, spokenWords > 0 else { return nil }
        return Double(spokenWords) / speakingMinutes
    }

    /// How many times faster speaking was than typing.
    var speedup: Double? {
        speakingWordsPerMinute.map { $0 / typingWordsPerMinute }
    }

    init(records: [TranscriptionRecord], period: UsagePeriod, typingWordsPerMinute: Double = HomeWeek.typingWordsPerMinute,
         now: Date = Date(), calendar: Calendar = .current) {
        self.typingWordsPerMinute = typingWordsPerMinute
        let today = calendar.startOfDay(for: now)
        since = records.map(\.date).min()

        // The period's first day: the period back from today, or History's oldest day.
        let first: Date
        if let days = period.days {
            first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        } else {
            first = since.map { calendar.startOfDay(for: $0) } ?? today
        }
        let span = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        granularity = span <= 31 ? .day : span <= 120 ? .week : .month
        // The chart starts at History's oldest day when the period reaches further back,
        // rather than with a row of empty bars for days nothing could have been dictated
        // — though never with fewer than a week of days or a month of weeks. The scale
        // (`granularity`) is still the period's.
        var chartStart = first
        if let since, calendar.startOfDay(for: since) > first {
            let shortest = granularity == .day
                ? calendar.date(byAdding: .day, value: -6, to: today)
                : calendar.date(byAdding: .weekOfYear, value: -3, to: today)
            chartStart = min(calendar.startOfDay(for: since), shortest ?? today)
            if chartStart > first { chartSince = calendar.startOfDay(for: since) }
        }
        buckets = Self.bucketStarts(from: max(first, chartStart), to: today, granularity: granularity, calendar: calendar)
            .map { Bucket(start: $0) }

        var unpriced: [String] = []
        var requestIndex: [String: Int] = [:]
        var engineIndex: [String: Int] = [:]
        var appIndex: [String: Int] = [:]

        func engine(_ step: EngineUse.Step, _ key: String, provider: String? = nil) -> Int {
            let id = "\(step)-\(key)-\(provider ?? "")"
            if let index = engineIndex[id] { return index }
            engines.append(EngineUse(step: step, key: key, provider: provider))
            engineIndex[id] = engines.count - 1
            return engines.count - 1
        }

        for record in records where record.date >= first && record.date <= now {
            dictations += 1
            let edit = record.refinement?.isSelectionEdit == true
            let kind: Kind = edit ? .edit : record.refinement?.succeeded == true ? .rewritten : .dictated
            let minutes = record.duration / 60
            let bucket = Self.bucketIndex(for: record.date, in: buckets, granularity: granularity, calendar: calendar)

            let cost = RecordCost(record)
            estimatedAIPasses += cost.estimatedAIPasses
            countRequests(record, index: &requestIndex)

            // The speech step — none for an edit sent with no instruction.
            let speech = cost.speech
            speechCost += speech
            if let bucket { buckets[bucket].speechCost += speech }
            if record.hasSpeech {
                let s = engine(.speech, record.provider, provider: record.sttModel)
                engines[s].uses += 1
                engines[s].minutes += minutes
                engines[s].isLocal = UsagePrices.speech(provider: record.provider, model: record.sttModel).isFree
                if cost.unpricedSpeech.isEmpty {
                    engines[s].cost = engines[s].cost.map { $0 + speech }
                } else {
                    engines[s].cost = nil
                    unpriced += cost.unpricedSpeech
                }
            }

            // The AI Rewrite step — what it cost even when a retry has since cleared the
            // pass it paid for.
            let ai = cost.ai
            aiCost += ai
            if let bucket { buckets[bucket].aiCost += ai }
            if let refinement = record.refinement {
                if edit { edits += 1 } else if refinement.succeeded { rewrites += 1 }
                let a = engine(.ai, refinement.model, provider: refinement.provider)
                engines[a].uses += 1
                if edit { engines[a].edits += 1 }
                if cost.unpricedChat.isEmpty {
                    engines[a].cost = engines[a].cost.map { $0 + ai }
                    engines[a].isLocal = UsagePrices.chat(provider: refinement.provider, model: refinement.model).isFree
                } else {
                    engines[a].cost = nil
                }
            }
            unpriced += cost.unpricedChat

            var use = kinds[kind] ?? KindUse()
            use.count += 1
            use.speechCost += speech
            use.aiCost += ai

            if record.status != .success || record.refinement?.succeeded == false { failed += 1 }
            if !edit, record.status == .success {
                let count = homeWordCount(record.deliveredText)
                words += count
                use.words += count
                let speaking = (record.speakingDuration ?? record.duration) / 60
                speakingMinutes += speaking
                spokenWords += homeWordCount(record.text)
                savedMinutes += max(0, Double(count) / typingWordsPerMinute - speaking)
                if let bucket {
                    if kind == .rewritten { buckets[bucket].rewrittenWords += count } else { buckets[bucket].dictatedWords += count }
                }
                let app = HomeRecentEntry.place(of: record)
                if appIndex[app] == nil { apps.append(AppUse(app: app)); appIndex[app] = apps.count - 1 }
                if let index = appIndex[app] {
                    apps[index].words += count
                    apps[index].dictations += 1
                }
            }
            kinds[kind] = use
        }

        var seen = Set<String>()
        unpricedModels = unpriced.filter { seen.insert($0).inserted }
        engines.sort { ($0.step == .speech ? 0 : 1, -($0.cost ?? 0), -$0.uses) < ($1.step == .speech ? 0 : 1, -($1.cost ?? 0), -$1.uses) }
        apps.sort { $0.words > $1.words }
        requests.sort { ($0.step == .speech ? 0 : 1, -$0.requests) < ($1.step == .speech ? 0 : 1, -$1.requests) }
    }

    /// One record's ledger into the per-model rows and the overhead. A record from before
    /// the ledger adds nothing: its requests were never written down.
    private mutating func countRequests(_ record: TranscriptionRecord, index: inout [String: Int]) {
        guard let events = record.usageEvents else { return }
        if ledgerSince.map({ record.date < $0 }) ?? true { ledgerSince = record.date }
        if events.isEmpty, record.status == .empty, record.duration > 0,
           let engine = STTProviderType(rawValue: record.provider), ![.apple, .local].contains(engine) {
            overhead.notSentSeconds += record.duration
        }
        // An upload beside a stream is the stream's fallback: nothing else uploads a
        // streamed segment, whether the socket broke or answered with nothing.
        let fellBack = events.contains { $0.kind == .stream } && events.contains { $0.kind == .upload }
        for event in events {
            let step: EngineUse.Step = event.kind.isSpeech ? .speech : .ai
            let key = "\(step)-\(event.vendor.rawValue)-\(event.model)"
            if index[key] == nil {
                requests.append(RequestUse(step: step, vendor: event.vendor, model: event.model))
                index[key] = requests.count - 1
            }
            guard let i = index[key] else { continue }
            requests[i].requests += 1
            if !event.succeeded {
                requests[i].failed += 1
                overhead.failedRequests += 1
            }
            requests[i].audioSeconds += event.audioSeconds ?? 0
            if let billed = event.billedSeconds {
                requests[i].billedSeconds += billed
                requests[i].billedRequests += 1
            }
            requests[i].inputTokens += event.tokens?.inputTokens ?? 0
            requests[i].outputTokens += event.tokens?.outputTokens ?? 0
            if let latency = event.latency, event.succeeded { requests[i].latencies.append(latency) }
            if event.kind == .stream, fellBack { overhead.paidTwiceSeconds += event.audioSeconds ?? 0 }
            if event.kind == .retry {
                overhead.retries += 1
                overhead.retrySeconds += event.audioSeconds ?? 0
            }
        }
    }

    /// Each bucket's first day, oldest first, ending with the one that holds today.
    static func bucketStarts(from first: Date, to today: Date, granularity: Granularity, calendar: Calendar) -> [Date] {
        var starts: [Date] = []
        var cursor: Date
        let step: Calendar.Component
        switch granularity {
        case .day:
            cursor = first; step = .day
        case .week:
            cursor = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first; step = .weekOfYear
        case .month:
            cursor = calendar.dateInterval(of: .month, for: first)?.start ?? first; step = .month
        }
        while cursor <= today {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }
        return starts
    }

    private static func bucketIndex(for date: Date, in buckets: [Bucket], granularity: Granularity,
                                    calendar: Calendar) -> Int? {
        buckets.lastIndex { $0.start <= date }
    }

    /// The tallest bar's words — the chart's scale.
    var mostWords: Int { buckets.map(\.words).max() ?? 0 }
    var mostCost: Double { buckets.map(\.cost).max() ?? 0 }
}

/// The Usage page's summaries as they were last worked out, kept until History, the typing
/// speed or the day changes: the page's body runs again whenever SwiftUI redraws it, and
/// each time that was every record History holds priced and counted. Each period is kept,
/// so switching back to one costs nothing.
final class UsageSummaryCache {
    private struct Key: Equatable {
        let records: [TranscriptionRecord]
        let typingWordsPerMinute: Double
        /// What the periods and the chart's buckets count back from.
        let today: Date
        let calendar: Calendar
    }

    private var key: Key?
    private var summaries: [UsagePeriod: UsageSummary] = [:]

    func summary(records: [TranscriptionRecord], period: UsagePeriod, typingWordsPerMinute: Double,
                 now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        // An unchanged History is the same array, which compares at once.
        let key = Key(records: records, typingWordsPerMinute: typingWordsPerMinute,
                      today: calendar.startOfDay(for: now), calendar: calendar)
        if key != self.key {
            self.key = key
            summaries = [:]
        }
        if let summary = summaries[period] { return summary }
        let summary = UsageSummary(records: records, period: period, typingWordsPerMinute: typingWordsPerMinute,
                                   now: now, calendar: calendar)
        summaries[period] = summary
        return summary
    }
}

// MARK: - Formatting

enum UsageFormat {
    /// A bar's label under the chart: "Mon" for a week of days, "14" for a month of them,
    /// "28 Sep" for a week, "Sep" for a month.
    static func label(_ start: Date, granularity: UsageSummary.Granularity, dayCount: Int,
                      calendar: Calendar = .current) -> String {
        let format = switch granularity {
        case .day: dayCount <= 7 ? "EEE" : "d"
        case .week: "d MMM"
        case .month: "MMM"
        }
        return HistoryFormat.formatter(format, calendar: calendar).string(from: start)
    }

    /// What a bar is, in full, for its tooltip: "Monday 28 September", "Week of 28
    /// September", "September 2026".
    static func title(_ start: Date, granularity: UsageSummary.Granularity, calendar: Calendar = .current) -> String {
        switch granularity {
        case .day: HistoryFormat.formatter("EEEE d MMMM", calendar: calendar).string(from: start)
        case .week: "Week of " + HistoryFormat.formatter("d MMMM", calendar: calendar).string(from: start)
        case .month: HistoryFormat.formatter("MMMM yyyy", calendar: calendar).string(from: start)
        }
    }

    /// "820", "48.2k", "1.3M" tokens.
    static func tokens(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: value < 10_000 ? "%.1fk" : "%.0fk", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    /// An answer's wait: "0.4 s", "12 s".
    static func wait(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }

    /// Audio: "45 s", "12 min", "1 h 5 min".
    static func audio(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : HomeFormat.durationText(minutes: seconds / 60)
    }

    /// "3.6×", "12×".
    static func speedup(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))×" : String(format: "%.1f×", value)
    }

    /// A small cost as a person would say it: "$0.75", "0.3¢".
    static func cents(_ value: Double) -> String {
        if value >= 0.01 { return HomeFormat.money(value) }
        if value <= 0 { return "$0" }
        let cents = value * 100
        return String(format: cents >= 0.1 ? "%.1f¢" : "%.2f¢", cents)
    }
}
