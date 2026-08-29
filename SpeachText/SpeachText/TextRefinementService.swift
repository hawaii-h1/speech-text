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
        /// Set when the dictation asked for the text to be delivered somewhere rather
        /// than pasted at the cursor.
        var sendIntent: SendIntent? = nil
    }

    /// The model's reading of "send this to X on Y", straight from the transcript.
    /// `recipient` is whatever the user called the person — resolving it to an actual
    /// address is `ContactResolver`'s job, never the model's.
    struct SendIntent: Equatable {
        let channel: DeliveryChannel
        let recipient: String
        let subject: String?
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
        let channels = MessageDelivery.isEnabled ? MessageDelivery.availableChannels : []
        let system = buildSystemPrompt(presets: presets, deliveryChannels: channels)

        let raw = try await provider.complete(
            system: system,
            user: "<transcript>\n\(source)\n</transcript>"
        )

        let parsed = parse(raw, allowing: channels)
        dlog("Refine", "preset=\(parsed.presetName ?? "—"), in=\(source.count) chars, out=\(parsed.text.count) chars, send=\(parsed.sendIntent?.channel.rawValue ?? "—")")

        guard !parsed.text.isEmpty else { throw LLMError.emptyResponse }
        return Result(text: parsed.text, presetName: parsed.presetName,
                      provider: providerType.rawValue, model: modelID,
                      sendIntent: parsed.sendIntent)
    }

    // MARK: - Prompt construction

    static func buildSystemPrompt(presets: [PromptPreset],
                                  deliveryChannels: [DeliveryChannel] = []) -> String {
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

        \(modes)\(deliverySection(for: deliveryChannels))

        Response format:
        Line 1 must be exactly `<<mode:NAME>>` where NAME is the mode you chose.
        Everything after the marker line(s) is the final text, and only the final text.
        """
    }

    /// The contract for turning a dictation into a delivered message. Left out entirely
    /// when message sending is off or no supported client is installed, so the ordinary
    /// paste-at-cursor behaviour is never described in terms the model could misapply.
    private static func deliverySection(for channels: [DeliveryChannel]) -> String {
        guard !channels.isEmpty else { return "" }
        let list = channels.map(\.rawValue).joined(separator: ", ")

        return """


        Delivering the text somewhere:
        The user can ask for the text to be sent to someone instead of pasted. If — and \
        only if — the transcript names BOTH a recipient AND one of the channels below, \
        add a second line immediately after the mode line:

        <<send:CHANNEL to="RECIPIENT" subject="SUBJECT">>

        - CHANNEL is exactly one of: \(list)
        - RECIPIENT is the person as the user named them, unchanged, in the language and \
        grammatical form it was said. NEVER invent, complete or "correct" a phone number, \
        email address or username: the app looks the person up in the user's own address \
        book. Write an address here only when the user dictated the address itself.
        - subject="…" is optional and only used by mail. Leave it out otherwise.
        - Everything after this line is the message body — what the user wants said, with \
        no greeting or sign-off they did not ask for, and no mention of the recipient or \
        the channel.

        If the transcript does not clearly name both a recipient and a channel, leave this \
        line out and the text is pasted at the cursor as usual. When in doubt, leave it out.
        """
    }

    // MARK: - Response parsing

    /// Strips the leading `<<mode:NAME>>` and `<<send:…>>` markers if the model emitted
    /// them, plus any stray code fence the model wrapped the answer in.
    ///
    /// `channels` is the allow-list: a send marker naming anything else — a channel the
    /// user disabled, or one the model made up — is dropped and the text is pasted as
    /// usual. A misrouted send is worse than a missed one.
    static func parse(_ raw: String, allowing channels: [DeliveryChannel] = []) -> Result {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var presetName: String?
        var sendIntent: SendIntent?

        // Order isn't guaranteed: models occasionally lead with the send marker.
        for _ in 0..<2 {
            if presetName == nil, let (value, rest) = takeMarker(prefix: "<<mode:", from: body) {
                presetName = value.trimmingCharacters(in: .whitespaces)
                body = rest
            } else if sendIntent == nil, let (value, rest) = takeMarker(prefix: "<<send:", from: body) {
                sendIntent = parseSendMarker(value, allowing: channels)
                body = rest
            } else {
                break
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        body = stripWrappingCodeFence(body)
        return Result(text: body, presetName: presetName?.isEmpty == false ? presetName : nil,
                      provider: "", model: "", sendIntent: sendIntent)
    }

    /// Splits `<<prefix … >>` off the front, returning the marker's contents and the rest.
    private static func takeMarker(prefix: String, from text: String) -> (String, String)? {
        guard text.hasPrefix(prefix), let close = text.range(of: ">>") else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        guard start <= close.lowerBound else { return nil }
        return (String(text[start ..< close.lowerBound]), String(text[close.upperBound...]))
    }

    /// `imessage to="Оксана" subject="…"` → a `SendIntent`, or nil if it names a channel
    /// that isn't on offer or carries no recipient at all.
    private static func parseSendMarker(_ marker: String, allowing channels: [DeliveryChannel]) -> SendIntent? {
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        let channelToken = trimmed.prefix { !$0.isWhitespace }.lowercased()

        guard let channel = DeliveryChannel(rawValue: channelToken), channels.contains(channel) else {
            dlog("Refine", "dropping send marker for unavailable channel “\(channelToken)”")
            return nil
        }

        let attributes = parseAttributes(String(trimmed.dropFirst(channelToken.count)))
        guard let recipient = attributes["to"]?.trimmingCharacters(in: .whitespaces),
              !recipient.isEmpty else {
            dlog("Refine", "dropping send marker with no recipient")
            return nil
        }

        let subject = attributes["subject"]?.trimmingCharacters(in: .whitespaces)
        return SendIntent(channel: channel, recipient: recipient,
                          subject: (subject?.isEmpty == false) ? subject : nil)
    }

    /// Reads `key="value"` pairs, tolerating the unquoted single-word form models
    /// sometimes fall back to.
    private static func parseAttributes(_ text: String) -> [String: String] {
        let patterns = ["([A-Za-z_]+)\\s*=\\s*\"([^\"]*)\"", "([A-Za-z_]+)\\s*=\\s*([^\\s\"]+)"]
        var found: [String: String] = [:]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text) else { continue }
                let key = String(text[keyRange]).lowercased()
                if found[key] == nil { found[key] = String(text[valueRange]) }
            }
        }
        return found
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
