// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Model

/// One "topic" the LLM can apply to a dictation.
///
/// `whenToUse` is what the model reads to decide whether this preset matches the
/// dictation — it is the routing signal, so it should describe the *situation*,
/// not the output. `instructions` is what the model applies once it has picked
/// this preset.
struct PromptPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var whenToUse: String
    var instructions: String

    init(id: UUID = UUID(), name: String, whenToUse: String, instructions: String) {
        self.id = id
        self.name = name
        self.whenToUse = whenToUse
        self.instructions = instructions
    }
}

// MARK: - Store

enum PromptPresetStore {
    /// Stable IDs so `defaultPresetID` keeps pointing at the right preset across launches.
    private static func fixedID(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!
    }

    static let cleanupPresetID = fixedID("01")

    static let builtInDefaults: [PromptPreset] = [
        PromptPreset(
            id: cleanupPresetID,
            name: "Clean-up",
            whenToUse: """
            The dictation is plain content with no instruction about style, format or \
            language — the user just wants what they said, written down properly.
            """,
            instructions: """
            Rewrite the dictation as clean written text. Fix speech-recognition errors, \
            misheard words, punctuation, capitalization and paragraph breaks. Remove \
            filler words, stutters, repetitions and false starts. Keep the user's own \
            wording, tone and language — do not translate, do not summarise, do not add \
            anything that was not said.
            """
        ),
        PromptPreset(
            id: fixedID("02"),
            name: "Rewrite / Draft",
            whenToUse: """
            The user dictated a rough draft and asked to write, rewrite, polish, expand \
            or shorten it, or asked for a particular style or tone.
            """,
            instructions: """
            Turn the draft into well-written prose that follows whatever style, tone, \
            length or audience the user described. Keep every fact and intent from the \
            draft; invent nothing. If no style was named, write clear, natural prose.
            """
        ),
        PromptPreset(
            id: fixedID("03"),
            name: "Email / Message",
            whenToUse: """
            The user asked for an email, letter, Slack or chat message, a reply, or any \
            text addressed to another person.
            """,
            instructions: """
            Write the message. Match the register the user asked for (formal, friendly, \
            terse…); default to polite and professional. Include a greeting and sign-off \
            only if the format calls for it. Do not invent names, dates or facts — leave \
            an obvious placeholder such as [name] when something is genuinely missing.
            """
        ),
        PromptPreset(
            id: fixedID("04"),
            name: "Translate",
            whenToUse: """
            The user asked to translate, or asked for the text in a specific language \
            different from the one they dictated in.
            """,
            instructions: """
            Produce the text in the requested target language. Translate meaning, not \
            words — the result must read as if it were written natively. Preserve tone \
            and formatting. Output only the translation.
            """
        ),
        PromptPreset(
            id: fixedID("05"),
            name: "Notes / Bullets",
            whenToUse: """
            The user asked for a summary, notes, bullet points, a list, a to-do list, or \
            for their rambling to be structured.
            """,
            instructions: """
            Structure the content as compact bullet points or a short list, grouped by \
            topic, in the order the user raised them. Use plain "- " bullets. One idea \
            per line, no padding, no closing commentary.
            """
        ),
        PromptPreset(
            id: fixedID("06"),
            name: "Technical / Prompt",
            whenToUse: """
            The user dictated something technical: a commit message, a PR or ticket \
            description, a bug report, or an instruction meant for an AI coding tool.
            """,
            instructions: """
            Write it in the conventional format for that artefact — imperative mood for \
            commit messages, problem/steps/expected for bug reports, an explicit \
            step-by-step task description for an AI coding instruction. Keep identifiers, \
            paths, commands and code fragments exactly as dictated; correct only obvious \
            speech-recognition mangling of them.
            """
        ),
    ]

    static func load() -> [PromptPreset] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.promptPresets),
              let decoded = try? JSONDecoder().decode([PromptPreset].self, from: data),
              !decoded.isEmpty
        else {
            return builtInDefaults
        }
        return decoded
    }

    static func save(_ presets: [PromptPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: SettingsKeys.promptPresets)
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.promptPresets)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.defaultPresetID)
    }

    /// The preset the model falls back to when nothing else clearly matches, given what
    /// the user chose. Pure, so the routing prompt can be built without reading the user's
    /// settings — the split is the same one `resolveLocale` / `resolvedLocale()` makes,
    /// and for the same reason: the tests must not touch `UserDefaults`.
    static func defaultPreset(in presets: [PromptPreset], storedID: UUID?) -> PromptPreset? {
        if let storedID, let match = presets.first(where: { $0.id == storedID }) {
            return match
        }
        return presets.first(where: { $0.id == cleanupPresetID }) ?? presets.first
    }

    /// The same answer for the app, which has the user's settings to read.
    static func defaultPreset(in presets: [PromptPreset]) -> PromptPreset? {
        defaultPreset(in: presets, storedID: storedDefaultPresetID())
    }

    /// The chosen fallback's id as stored, or nil when the user never picked one.
    static func storedDefaultPresetID() -> UUID? {
        UserDefaults.standard.string(forKey: SettingsKeys.defaultPresetID)
            .flatMap(UUID.init(uuidString:))
    }

    static func setDefaultPreset(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: SettingsKeys.defaultPresetID)
    }
}
