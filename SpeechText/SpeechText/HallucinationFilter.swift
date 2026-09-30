// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Known hallucinations

/// What a speech model says when there was nothing to hear. Whisper was trained on
/// subtitled video, so silence or a breath comes back as a subtitle's sign-off ("Thank
/// you for watching", "Субтитры сделал DimaTorzok"); a stream opened on silence has
/// answered "Evet." and "Seyit." (#74, pasted twice in the #47 pass). No vendor
/// documents it, so the filter is ours.
///
/// Deliberately narrow: a phrase is dropped only when it is the *whole* result of a
/// short segment. The same words inside a real dictation are left alone, and so is a
/// short segment that says anything else — a filter that guesses would delete speech.
/// Phrases a person plausibly dictates on their own ("Thank you", "Дякую за увагу")
/// are not on the list, however often a model invents them.
///
/// Pure logic, in both targets.
enum HallucinationFilter {
    /// Compared after `normalized`: lowercase, letters and digits only, one space
    /// between words.
    static let phrases: Set<String> = [
        // English
        "thank you for watching",
        "thanks for watching",
        "thank you for watching and see you next time",
        "thank you so much for watching",
        "please subscribe",
        "please like and subscribe",
        "like and subscribe",
        "subscribe to the channel",
        "see you in the next video",
        // Turkish — measured in this app's own streams (#47)
        "evet",
        "seyit",
        "abone olmayı unutmayın",
        // Ukrainian
        "дякую за перегляд",
        "дякуємо за перегляд",
        "дякую за перегляд до зустрічі",
        "продовження далі",
        "підписуйтесь на канал",
        "субтитрування dimatorzok",
        // Russian
        "спасибо за просмотр",
        "продолжение следует",
        "подписывайтесь на канал",
    ]

    /// Subtitle credits, which carry a name after them ("Субтитры сделал DimaTorzok",
    /// "Субтитри створено спільнотою Amara.org"): a whole result that *begins* with one of these is a
    /// credit line, not speech. Each is the credit's own wording, never a lone word or a
    /// loose pair — "Субтитры готовы" and "Subtitles by tomorrow" are things people say.
    static let prefixes: [String] = [
        "subtitles by the amara org community",
        "субтитры сделал",
        "субтитры создавал",
        "субтитры подготовлены",
        "субтитры делал",
        "редактор субтитров",
        "субтитри створено",
        "субтитри зроблено",
        "altyazı m k",
    ]

    /// True when `text` is nothing but a known hallucination and the segment it came
    /// from was no longer than `STTTuning.hallucinationSegmentSeconds`. A duration of 0
    /// means "not measured" and counts as short: the phrase alone is the evidence then.
    static func isHallucination(_ text: String, segmentSeconds: TimeInterval) -> Bool {
        guard segmentSeconds <= STTTuning.hallucinationSegmentSeconds else { return false }
        let words = normalized(text)
        guard !words.isEmpty else { return false }
        if phrases.contains(words) { return true }
        return prefixes.contains { words == $0 || words.hasPrefix($0 + " ") }
    }

    /// Lowercased, punctuation and symbols dropped, words separated by one space.
    /// Apostrophes are dropped rather than split on, so "Don't" stays one word.
    static func normalized(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" || character == "ʼ" {
                continue
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }
}
