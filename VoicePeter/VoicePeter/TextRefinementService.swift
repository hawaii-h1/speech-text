import Foundation

/// Runs a finished transcription through an LLM, which picks the best-matching
/// prompt preset for what the user actually asked for and applies it.
enum TextRefinementService {

    struct Result {
        let text: String
        /// Name of the preset the model routed to, when it reported one.
        let presetName: String?
        let provider: String
        let model: String
    }

    static var isConfigured: Bool { LLMConfiguration.isConfigured }

    // MARK: - Entry point

    static func refine(_ transcript: String) async throws -> Result {
        let source = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerType = LLMConfiguration.providerType
        let modelID = LLMConfiguration.model(for: providerType)
        guard !source.isEmpty else {
            return Result(text: "", presetName: nil,
                          provider: providerType.rawValue, model: modelID)
        }

        let provider = try LLMConfiguration.makeProvider()
        let presets = PromptPresetStore.load()
        let system = buildSystemPrompt(presets: presets)

        let raw = try await provider.complete(
            system: system,
            user: "<transcript>\n\(source)\n</transcript>"
        )

        let parsed = parse(raw)
        dlog("Refine", "preset=\(parsed.presetName ?? "—"), in=\(source.count) chars, out=\(parsed.text.count) chars")

        guard !parsed.text.isEmpty else { throw LLMError.emptyResponse }
        return Result(text: parsed.text, presetName: parsed.presetName,
                      provider: providerType.rawValue, model: modelID)
    }

    // MARK: - Prompt construction

    static func buildSystemPrompt(presets: [PromptPreset]) -> String {
        let fallback = PromptPresetStore.defaultPreset(in: presets)

        let modes = presets.map { preset -> String in
            let marker = preset.id == fallback?.id ? "  (DEFAULT — use when nothing else clearly fits)" : ""
            return """
            ### \(preset.name)\(marker)
            When to use: \(preset.whenToUse.trimmingCharacters(in: .whitespacesAndNewlines))
            Instructions: \(preset.instructions.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }.joined(separator: "\n\n")

        return """
        You are the text engine of a dictation app. The user speaks out loud and \
        speech-to-text produces a raw transcript, delivered to you inside <transcript> tags.

        That transcript IS the user's request. It may contain an instruction (what to \
        write, in which style, in which language), the content itself, or both mixed \
        together. Your output is pasted straight into whatever app the user was typing \
        in, at their cursor.

        How to respond:
        1. Read the transcript and decide which single mode below best matches what the \
        user is asking for.
        2. Apply that mode's instructions to produce the final text.
        3. Output that text and nothing else.

        Hard rules:
        - Never reply conversationally. No greetings, no preamble, no explanation, no \
        commentary, no follow-up questions, no "Here is…".
        - Never repeat the user's instruction back. If the transcript is "write an email \
        to Anna about being late", output the email — not the sentence describing it.
        - Never wrap the output in quotation marks or markdown code fences, unless the \
        user explicitly asked for code or a code block.
        - Expect speech-recognition noise: fix misheard words, homophones, missing \
        punctuation and capitalization, and drop filler words.
        - Spoken formatting commands ("new paragraph", "bullet point", "in quotes") are \
        instructions, not content — apply them.
        - Output language: whichever language the user asked for. If they did not ask, \
        use the language of the dictated content.
        - If the transcript is too short or garbled to act on, output it cleaned up and \
        unchanged rather than inventing content.

        Available modes:

        \(modes)

        Response format:
        Line 1 must be exactly `<<mode:NAME>>` where NAME is the mode you chose.
        Everything after line 1 is the final text, and only the final text.
        """
    }

    // MARK: - Response parsing

    /// Strips the leading `<<mode:NAME>>` marker if the model emitted one, plus any
    /// stray code fence the model wrapped the answer in.
    static func parse(_ raw: String) -> Result {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var presetName: String?

        if body.hasPrefix("<<mode:"), let close = body.range(of: ">>") {
            presetName = String(body[body.index(body.startIndex, offsetBy: 7) ..< close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            body = String(body[close.upperBound...])
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        body = stripWrappingCodeFence(body)
        return Result(text: body, presetName: presetName?.isEmpty == false ? presetName : nil,
                      provider: "", model: "")
    }

    /// Removes a fence only when it wraps the *entire* response — a fenced snippet
    /// inside a longer answer is content the user asked for.
    private static func stripWrappingCodeFence(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2,
              lines.first?.hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```",
              !lines.dropFirst().dropLast().contains(where: { $0.hasPrefix("```") })
        else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
