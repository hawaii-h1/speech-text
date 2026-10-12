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
    /// AI passes this week priced from their words, not their tokens: written before the
    /// provider's usage was kept.
    var estimatedAIPasses = 0
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
            let cost = RecordCost(record)
            speechCost += cost.speech
            aiCost += cost.ai
            estimatedAIPasses += cost.estimatedAIPasses
            unpriced += cost.unpricedSpeech + cost.unpricedChat

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
    /// Whether Home and Usage show any dollar figure. Off until it is decided how the
    /// prices are kept current (#129): a list price that has moved since it was written
    /// down misstates every total built on it, and the units — minutes, tokens, requests,
    /// limits — are exact without one. The pricing below stays, tested, for when it is on.
    static let shown = false

    struct Chat: Equatable {
        let inputPerToken: Double
        let outputPerToken: Double

        var isFree: Bool { inputPerToken == 0 && outputPerToken == 0 }

        /// What one LLM pass cost: the tokens the provider reported billing, else — for a
        /// pass recorded before they were kept — the estimate from its words. Home and
        /// Usage both price a pass through here, so they cannot disagree.
        func cost(of refinement: TranscriptionRecord.Refinement) -> Double {
            if let usage = refinement.usage { return cost(usage) }
            return cost(inputWords: homeWordCount(refinement.inputText),
                        outputWords: homeWordCount(refinement.outputText))
        }

        /// Every input token at the input price, cached ones included — a cache read is
        /// cheaper, so this errs high until the catalogue carries cached prices (#129).
        func cost(_ usage: ChatUsage) -> Double {
            Double(usage.inputTokens) * inputPerToken + Double(usage.outputTokens) * outputPerToken
        }

        /// The design's estimate: the routing prompt (~1,100 tokens) plus the words sent,
        /// and the words returned, at 1.4 tokens a word. Only for passes recorded before
        /// the reply's usage was kept: it misses the presets, the context and vocabulary
        /// blocks, any reasoning, and Cyrillic's heavier tokenisation.
        func cost(inputWords: Int, outputWords: Int) -> Double {
            (1_100 + Double(inputWords) * 1.4) * inputPerToken + Double(outputWords) * 1.4 * outputPerToken
        }

        /// Whether `cost(of:)` had to estimate this pass's price rather than count it.
        func isEstimate(_ refinement: TranscriptionRecord.Refinement) -> Bool {
            !isFree && refinement.usage == nil
        }
    }

    /// Dollars per minute of speech from `vendor`, the one a ledger entry names.
    static func speech(vendor: Provider) -> Double? {
        STTProviderType.allCases.first { $0.vendor == vendor }.flatMap { speech(provider: $0.rawValue) }
    }

    /// Dollars per minute of speech, by `STTProviderType` raw value; nil when not priced.
    static func speech(provider: String) -> Double? {
        switch STTProviderType(rawValue: provider) {
        case .apple?, .local?: 0
        case .groq?: 0.04 / 60
        case .elevenlabs?: 0.40 / 60
        case .openai?: nil // not priced yet (#129)
        case nil: nil
        }
    }

    /// A chat model's token prices, for the vendor a ledger entry names.
    static func chat(vendor: Provider, model: String) -> Chat? {
        chat(provider: vendor == .ollama ? LLMProviderType.ollama.rawValue : vendor.rawValue, model: model)
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

/// What one History record cost, worked out the one way Home and Usage both count it.
/// A record with a ledger (`usageEvents`) is priced from its entries alone — every
/// request it made, a fallback upload and a retry included, the vendor's billed seconds
/// where it reported them. One from before the ledger is priced as it always was: its
/// length at its engine's price, and its AI pass from `Chat.cost(of:)`.
struct RecordCost: Equatable {
    var speech: Double = 0
    var ai: Double = 0
    /// Engines (`STTProviderType` raw values) and chat models used here with no price.
    var unpricedSpeech: [String] = []
    var unpricedChat: [String] = []
    /// AI passes priced from their words rather than their tokens.
    var estimatedAIPasses = 0

    var total: Double { speech + ai }

    init(_ record: TranscriptionRecord) {
        guard let events = record.usageEvents else {
            if !record.hasSpeech {
                // An edit with no instruction: nothing was heard, nothing to price.
            } else if let price = UsagePrices.speech(provider: record.provider) {
                speech = record.duration / 60 * price
            } else {
                unpricedSpeech.append(record.provider)
            }
            if let refinement = record.refinement { price(refinement) }
            return
        }
        for event in events {
            if !event.kind.isSpeech {
                guard let price = UsagePrices.chat(vendor: event.vendor, model: event.model) else {
                    unpricedChat.append(event.model)
                    continue
                }
                if let tokens = event.tokens {
                    ai += price.cost(tokens)
                } else if event.succeeded, let refinement = record.refinement, !price.isFree {
                    // Answered, but its provider reported no tokens: the words are all
                    // there is to go on.
                    ai += price.cost(inputWords: homeWordCount(refinement.inputText),
                                     outputWords: homeWordCount(refinement.outputText))
                    estimatedAIPasses += 1
                }
            } else if let seconds = event.billedSeconds ?? event.audioSeconds,
                      // A refused upload is not taken as billed (`UsageMeter.event`); a
                      // socket was used whatever became of its answer.
                      event.succeeded || event.kind == .stream {
                guard let price = UsagePrices.speech(vendor: event.vendor) else {
                    unpricedSpeech.append(STTProviderType.allCases.first { $0.vendor == event.vendor }?.rawValue
                                          ?? event.vendor.rawValue)
                    continue
                }
                speech += seconds / 60 * price
            }
        }
    }

    private mutating func price(_ refinement: TranscriptionRecord.Refinement) {
        guard let price = UsagePrices.chat(provider: refinement.provider, model: refinement.model) else {
            unpricedChat.append(refinement.model)
            return
        }
        ai += price.cost(of: refinement)
        if price.isEstimate(refinement) { estimatedAIPasses += 1 }
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

    /// The text as a row shows it: every run of whitespace — a paragraph break above all —
    /// one space, so a letter's "Hi Amie!" and blank line do not leave the row's second
    /// line empty. `text` keeps the line breaks for Copy.
    var preview: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
/// (rewritten first on the AI tab; on the Edit tab a selection is replaced by what the
/// instruction asked for). Its phases, Rewriting… while AI works and the one paste at the
/// stop are the design's approved animation. The keys press one after another, quickly,
/// and with hold to talk the modifiers are let go while the letter stays down — changed at
/// the owner's call on 2026-10-12, so the card teaches what the hold tip does.
struct HomeTalk: Equatable {
    enum Phase: Equatable { case idle, hear, work, done }
    enum Mode: Equatable { case dictate, ai, edit }

    struct Script: Equatable {
        let app: String
        let place: String
        let said: [String]
        let output: String
        /// The preset the rewrite reports, shown beside the pasted text.
        let preset: String?
        /// The text selected before an edit, which its output replaces.
        var selection: String? = nil
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

    static let edit = Script(
        app: "Notes", place: "Trip plan",
        said: "make it sound more sure".split(separator: " ").map(String.init),
        output: "Let's go on Friday — it works for everyone.",
        preset: nil,
        selection: "i think maybe we could go on friday if thats ok for everyone")

    /// One tick is 100 ms.
    static let tickSeconds = 0.1

    let script: Script
    let mode: Mode
    let phase: Phase
    /// Words heard so far.
    let heard: Int
    /// Which of the shortcut's caps are down, by index — the modifiers first, the letter
    /// last, as the caps are drawn.
    let litKeys: Set<Int>

    /// The text goes to AI — a rewrite or an edit; the overlay is violet.
    var isAI: Bool { mode != .dictate }
    var isEdit: Bool { mode == .edit }
    /// Every key is down.
    var keysDown: Bool { !litKeys.isEmpty }

    init(tick: Int, mode: Mode, holdToTalk: Bool, keyCount: Int = 3) {
        let script = switch mode { case .dictate: Self.dictate; case .ai: Self.ai; case .edit: Self.edit }
        let idle = 8, hear = script.said.count * 4, work = mode == .dictate ? 3 : 14, show = 30
        let k = tick % (idle + hear + work + show)
        let phase: Phase = k < idle ? .idle : k < idle + hear ? .hear : k < idle + hear + work ? .work : .done
        self.script = script
        self.mode = mode
        self.phase = phase
        heard = switch phase {
        case .idle: 0
        case .hear: (k - idle) / 4 + 1
        case .work, .done: script.said.count
        }
        litKeys = Self.keys(at: k, idle: idle, hear: hear, holdToTalk: holdToTalk, count: keyCount)
    }

    /// The keys go down one after another, a tick apart, the letter last and just as the
    /// overlay starts listening. With hold to talk the modifiers come up shortly after —
    /// only the letter has to stay down — and the letter at the stop; otherwise the whole
    /// shortcut is tapped at the start and again at the stop.
    static func keys(at k: Int, idle: Int, hear: Int, holdToTalk: Bool, count: Int) -> Set<Int> {
        let count = max(1, min(count, idle))
        let letter = count - 1
        let pressed = idle - letter
        let stop = idle + hear
        func cascade(from start: Int, until end: Int) -> Set<Int> {
            guard k >= start, k < end else { return [] }
            return Set((0..<count).filter { k >= start + $0 })
        }
        if holdToTalk {
            let modifiersUp = idle + 4
            if k < modifiersUp { return cascade(from: pressed, until: modifiersUp) }
            return k < stop ? [letter] : []
        }
        return cascade(from: pressed, until: idle + 2).union(cascade(from: stop - count, until: stop))
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

    /// What the message holds: the selection waiting to be edited, nothing but the caret
    /// (before a paste, and once an edit's instruction is over and the selection is cut),
    /// or the text pasted.
    enum Message: Equatable { case caret, selection(String), pasted }

    var message: Message {
        if phase == .done { return .pasted }
        if let selection = script.selection, phase != .work { return .selection(selection) }
        return .caret
    }

    /// The dot matrix — `PixelDisplayMode`, which this file cannot name: the voice while
    /// it hears, the comet while AI Rewrite works, at rest before and after.
    enum Display: Equatable { case idle, level, busy }

    var display: Display {
        phase == .hear ? .level : phase == .work && isAI ? .busy : .idle
    }
}
