// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What the main window's Home says, worked out from History and the settings — pure, so
// the numbers and the intro card's animation are testable without a window.

// MARK: - The last 7 days

/// Home's week: what was dictated, the time it saved against typing, and what the
/// speaking cost at the providers' list prices — then each day's words, oldest first.
struct HomeWeek: Equatable {
    struct Day: Equatable {
        let date: Date
        let words: Int
        let isToday: Bool
    }

    /// Words that ended up as text. An edit's instruction is a command, not text, and a
    /// failed or empty dictation produced none.
    var words = 0
    var dictations = 0
    /// Minutes of speech behind those words.
    var speakingMinutes: Double = 0
    /// Typing the same words at `typingWordsPerMinute`, less the time spent saying them.
    var savedMinutes: Double = 0
    var speechCost: Double = 0
    var aiCost: Double = 0
    /// Cloud models used this week whose price `UsagePrices` does not know, so `spent`
    /// leaves them out.
    var unpricedModels: [String] = []
    var days: [Day] = []

    var spent: Double { speechCost + aiCost }

    /// An average typist, until the user sets their own speed (Usage › How this is
    /// counted).
    static let typingWordsPerMinute = 40.0

    init(records: [TranscriptionRecord], typingSpeed: Double = HomeWeek.typingWordsPerMinute,
         now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return }
        var perDay = Array(repeating: 0, count: 7)
        var unpriced: [String] = []

        for record in records where record.date >= start && record.date <= now {
            dictations += 1
            let edit = record.refinement?.isSelectionEdit == true
            let minutes = record.duration / 60
            let prices = UsagePrices.speech(provider: record.provider)
            if let prices { speechCost += minutes * prices } else { unpriced.append(record.provider) }

            if let refinement = record.refinement {
                let input = homeWordCount(refinement.inputText)
                let output = homeWordCount(refinement.outputText)
                if let price = UsagePrices.chat(provider: refinement.provider, model: refinement.model) {
                    aiCost += price.cost(inputWords: input, outputWords: output)
                } else {
                    unpriced.append(refinement.model)
                }
            }

            guard !edit, record.status == .success else { continue }
            let count = homeWordCount(record.deliveredText)
            words += count
            speakingMinutes += minutes
            savedMinutes += max(0, Double(count) / typingSpeed - minutes)
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: record.date)).day ?? 0
            if (0..<7).contains(day) { perDay[day] += count }
        }

        var seen = Set<String>()
        unpricedModels = unpriced.filter { seen.insert($0).inserted }
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return Day(date: date, words: perDay[offset], isToday: offset == 6)
        }
    }

    /// How many of `rows` dots a day's column lights: its share of the busiest day, never
    /// fewer than one for a day that has any words — the design's "a day is only as tall as
    /// its words".
    func litRows(for day: Day, rows: Int) -> Int {
        let most = days.map(\.words).max() ?? 0
        guard day.words > 0, most > 0 else { return 0 }
        return max(1, Int((Double(day.words) / Double(most) * Double(rows)).rounded()))
    }
}

func homeWordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
}

/// Pay-as-you-go list prices, as the main window's design gives them (checked
/// 28 September 2026). Only what the design priced is here: anything else is reported as
/// unpriced rather than guessed. What runs on the Mac costs nothing.
enum UsagePrices {
    struct Chat: Equatable {
        let inputPerToken: Double
        let outputPerToken: Double

        /// The design's estimate: the routing prompt (~1,100 tokens) plus the words sent,
        /// and the words returned, at 1.4 tokens a word.
        func cost(inputWords: Int, outputWords: Int) -> Double {
            (1_100 + Double(inputWords) * 1.4) * inputPerToken + Double(outputWords) * 1.4 * outputPerToken
        }
    }

    /// Dollars per minute of speech, by `STTProviderType` raw value; nil when not priced.
    static func speech(provider: String) -> Double? {
        switch provider {
        case STTProviderType.apple.rawValue, STTProviderType.local.rawValue: 0
        case STTProviderType.groq.rawValue: 0.04 / 60
        case STTProviderType.elevenlabs.rawValue: 0.40 / 60
        default: nil
        }
    }

    /// A chat model's token prices, by `LLMProviderType` raw value and model ID.
    static func chat(provider: String, model: String) -> Chat? {
        if provider == LLMProviderType.ollama.rawValue { return Chat(inputPerToken: 0, outputPerToken: 0) }
        switch model {
        case "claude-sonnet-5": return Chat(inputPerToken: 3 / 1e6, outputPerToken: 15 / 1e6)
        case "openai/gpt-oss-120b": return Chat(inputPerToken: 0.15 / 1e6, outputPerToken: 0.75 / 1e6)
        default: return nil
        }
    }
}

// MARK: - Formatting

enum HomeFormat {
    static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "52 min", "1 h 5 min", "2 h".
    static func duration(minutes: Double) -> (hours: Int?, minutes: Int?) {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return (nil, total) }
        let rest = total % 60
        return (total / 60, rest == 0 ? nil : rest)
    }

    static func durationText(minutes: Double) -> String {
        let (h, m) = duration(minutes: minutes)
        return [h.map { "\($0) h" }, m.map { "\($0) min" }].compactMap { $0 }.joined(separator: " ")
    }

    static func money(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value >= 100 { return "$" + integer(Int(value.rounded())) }
        return String(format: "$%.2f", value)
    }
}

// MARK: - Recent

/// One row of Home's Recent and of History: what was said, where it went and when, and
/// what rewrote it.
struct HomeRecentEntry: Equatable, Identifiable {
    enum Tag: Equatable {
        case preset(String)
        case edit
        /// AI Rewrite or an edit did not work: the dictated text was pasted, or the
        /// selection left as it was.
        case rewriteFailed
        case failed
    }

    let id: UUID
    let text: String
    /// The app the text went to; nil when History does not know (the Record Window, a
    /// dictation that pasted nothing, and entries from before the stop recorded it).
    let app: String?
    let date: Date
    let status: TranscriptionRecord.Status
    let tags: [Tag]
    let canRetry: Bool

    init(_ record: TranscriptionRecord) {
        id = record.id
        date = record.date
        status = record.status
        let edit = record.refinement?.isSelectionEdit == true
        switch record.status {
        case .success:
            // An edit that failed left the selection as it was — that is the text it is about.
            if edit, let refinement = record.refinement, !refinement.succeeded {
                text = refinement.inputText
            } else {
                text = record.deliveredText
            }
        case .empty:
            text = "Nothing was heard."
        case .failed:
            text = record.errorMessage ?? "Transcription failed."
        }
        app = record.destinationApp ?? record.refinement?.context?.appName ?? record.originApp
        var tags: [Tag] = []
        if edit {
            tags.append(.edit)
        } else if let refinement = record.refinement, refinement.succeeded, let preset = refinement.presetName {
            tags.append(.preset(preset))
        }
        if let refinement = record.refinement, !refinement.succeeded { tags.append(.rewriteFailed) }
        if record.status == .failed { tags.append(.failed) }
        self.tags = tags
        canRetry = record.isRetryable
    }

    /// Where the row says the text went: its app, the Record Window for a success that
    /// names none — or that nothing was pasted.
    var place: String {
        app ?? (status == .success ? "Record Window" : "Not pasted")
    }

    /// "14:02" today, "Yesterday", a weekday within the week, a date before that.
    func timeText(now: Date = Date(), calendar: Calendar = .current) -> String {
        Self.relativeDay(date, now: now, calendar: calendar)
    }

    /// `timeText` for any date.
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                     to: calendar.startOfDay(for: now)).day, days < 7 {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }
}

// MARK: - The intro card's picture

/// The intro card's picture, as a function of time: one dictation playing out on a loop —
/// the overlay hears it word by word, then the stop pastes it, once, into a message
/// (rewritten first on the AI tab). Its phases, the keys pressing with it, hold to talk
/// keeping them down, Rewriting… on AI and the one paste at the stop are the design's
/// approved animation — keep them as they are.
struct HomeTalk: Equatable {
    enum Phase: Equatable { case idle, hear, work, done }

    struct Script: Equatable {
        let app: String
        let place: String
        let said: [String]
        let output: String
        /// The preset the rewrite reports, shown beside the pasted text.
        let preset: String?
    }

    static let dictate = Script(
        app: "Slack", place: "#design",
        said: "Let's move the call to Thursday at three — I'll send the agenda tonight so everyone has a look before we meet".split(separator: " ").map(String.init),
        output: "Let's move the call to Thursday at three — I'll send the agenda tonight so everyone has a look before we meet.",
        preset: nil)

    static let ai = Script(
        app: "Mail", place: "To: Olena",
        said: "uh email to Olena running late start without me sorry".split(separator: " ").map(String.init),
        output: "Hi Olena, I'm running a few minutes late — please start without me. Sorry!",
        preset: "Email / Message")

    /// One tick is 100 ms.
    static let tickSeconds = 0.1

    let script: Script
    let isAI: Bool
    let phase: Phase
    /// Words heard so far.
    let heard: Int
    /// The shortcut's keys are down.
    let keysDown: Bool

    init(tick: Int, ai: Bool, holdToTalk: Bool) {
        let script = ai ? Self.ai : Self.dictate
        let idle = 8, hear = script.said.count * 4, work = ai ? 14 : 3, show = 30
        let k = tick % (idle + hear + work + show)
        let phase: Phase = k < idle ? .idle : k < idle + hear ? .hear : k < idle + hear + work ? .work : .done
        self.script = script
        isAI = ai
        self.phase = phase
        heard = switch phase {
        case .idle: 0
        case .hear: (k - idle) / 4 + 1
        case .work, .done: script.said.count
        }
        // With hold to talk the keys stay down while it listens; otherwise they tap at the
        // start and at the stop.
        keysDown = holdToTalk ? phase == .hear
            : (k >= idle && k < idle + 2) || (k >= idle + hear - 2 && k < idle + hear)
    }

    /// The transcript on the overlay's glass: the settled words, then the last two — the
    /// partial the engine may still take back — while it is hearing.
    var settled: String {
        let words = script.said.prefix(heard)
        let cut = phase == .hear ? max(0, words.count - 2) : words.count
        return words.prefix(cut).joined(separator: " ")
    }

    var partial: String {
        guard phase == .hear else { return "" }
        let words = script.said.prefix(heard)
        return words.suffix(from: max(0, words.count - 2)).joined(separator: " ")
    }

    /// What the glass says instead of words.
    enum Caption: Equatable { case listening, words, rewriting, pasted }

    var caption: Caption {
        switch phase {
        case .idle: .listening
        case .hear: .words
        case .work: isAI ? .rewriting : .words
        case .done: .pasted
        }
    }

    /// The dot matrix — `PixelDisplayMode`, which this file cannot name: the voice while
    /// it hears, the comet while AI Rewrite works, at rest before and after.
    enum Display: Equatable { case idle, level, busy }

    var display: Display {
        phase == .hear ? .level : phase == .work && isAI ? .busy : .idle
    }
}
