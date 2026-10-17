// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How a family of local chat models wants its conversation written out, and how to read
/// its reply. llama.cpp's C API has no Jinja — a model's own `tokenizer.chat_template` is
/// not run — so each family's format is written here by hand, from that template, for
/// the one shape AI Rewrite sends: a system prompt, one user message, and reasoning off.
///
/// Every rendering is checked token for token against `llama-server --jinja` by the
/// rewrite evaluation, and written out literally in `ChatTemplateTests`; a family whose
/// template changes upstream is a change here, made against that diff, never by feel.
enum ChatTemplateFamily: String, Codable, CaseIterable, Sendable {
    /// Qwen3.5 and Qwen3.8 (`qwen35` in GGUF): chatml. Thinking is switched off as the
    /// template's own `enable_thinking=false` does it — an empty `<think>` block already
    /// written into the assistant turn. Both trim the system and user text. No BOS.
    case qwen
    /// Gemma 4 (`gemma4`): `<|turn>role … <turn|>`, not Gemma 3's `<start_of_turn>`. The
    /// template writes `<bos>` itself, and with thinking off writes an empty thought
    /// channel into the model's turn. Trims the system and user text.
    case gemma4
    /// gpt-oss: OpenAI's Harmony. The template's own system message (identity, cutoff,
    /// date, `Reasoning:`, channels), our system prompt as the developer's `# Instructions`,
    /// and the user's message untrimmed. Reasoning cannot be switched off, only set to
    /// `low`; the model writes an `analysis` message first and the reply in `final`.
    case harmony
}

enum ChatTemplates {

    /// The prompt for one system + user exchange, ending where the model starts writing.
    /// Special tokens are written as text: the runtime tokenizes it with `parse_special`,
    /// and adds no BOS of its own (Gemma's is in the text, the others take none).
    /// `date` only reaches Harmony, whose system message carries the current date.
    static func render(_ family: ChatTemplateFamily, system: String, user: String,
                       date: Date = Date()) -> String {
        let prefix = cacheablePrefix(family, system: system, date: date)
        switch family {
        case .qwen:
            return prefix + "\n<|im_start|>user\n\(trimmed(user))<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .gemma4:
            return prefix + "\n<|turn>user\n\(trimmed(user))<turn|>\n"
                + "<|turn>model\n<|channel>thought\n<channel|>"
        case .harmony:
            return prefix + "<|start|>user<|message|>\(user)<|end|>"
                + "<|start|>assistant"
        }
    }

    /// The start of `render` that depends on the system prompt alone, ending on the special
    /// token that closes the system turn. Tokenization restarts after a special token, so
    /// its tokens are exactly the first tokens of the whole prompt: the runtime reads it
    /// once and restores its state for every later request with the same system prompt.
    static func cacheablePrefix(_ family: ChatTemplateFamily, system: String, date: Date = Date()) -> String {
        switch family {
        case .qwen:
            return "<|im_start|>system\n\(trimmed(system))<|im_end|>"
        case .gemma4:
            return "<bos><|turn>system\n\(trimmed(system))<turn|>"
        case .harmony:
            return "<|start|>system<|message|>"
                + "You are ChatGPT, a large language model trained by OpenAI.\n"
                + "Knowledge cutoff: 2024-06\n"
                + "Current date: \(harmonyDate(date))\n\n"
                + "Reasoning: low\n\n"
                + "# Valid channels: analysis, commentary, final. Channel must be included for every message."
                + "<|end|>"
                + "<|start|>developer<|message|># Instructions\n\n\(system)\n\n<|end|>"
        }
    }

    /// Whether `generated` — everything the model wrote so far, special tokens included —
    /// is a whole reply. Harmony is the one that needs it: its `<|end|>` closes the
    /// analysis message too, which llama.cpp reports as end-of-generation, so only the
    /// final channel's `<|return|>` (or its `<|end|>`) ends the reply.
    static func isComplete(_ generated: String, family: ChatTemplateFamily) -> Bool {
        switch family {
        case .qwen: return generated.contains("<|im_end|>")
        case .gemma4: return generated.contains("<turn|>")
        case .harmony:
            if generated.contains("<|return|>") { return true }
            guard let final = generated.range(of: "<|channel|>final") else { return false }
            return generated[final.upperBound...].contains("<|end|>")
        }
    }

    /// The text of the reply, out of everything the model wrote: Harmony's final channel
    /// only, never its analysis; for the others, everything before the end-of-turn marker,
    /// with a reasoning block the model wrote anyway taken off. A Harmony reply cut off
    /// before its final channel has no text — empty, which the caller treats as no reply,
    /// rather than the analysis pasted as if it were the rewrite.
    static func reply(from generated: String, family: ChatTemplateFamily) -> String {
        switch family {
        case .qwen:
            let body = generated.components(separatedBy: "<|im_end|>").first ?? ""
            return strippingReasoning(body)
        case .gemma4:
            var body = generated.components(separatedBy: "<turn|>").first ?? ""
            // A thought channel the model opened anyway: everything up to its close goes.
            if let open = body.range(of: "<|channel>") {
                if let close = body.range(of: "<channel|>", range: open.upperBound..<body.endIndex) {
                    body.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    body = String(body[..<open.lowerBound])
                }
            }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        case .harmony:
            // The final channel's header is not always `final<|message|>`: gpt-oss 20B also
            // writes `final <|constrain|>…<|message|>`, and now and then leaves `<|message|>`
            // out (measured 2026-10-16). Everything after `final`, header tokens taken out.
            guard let final = generated.range(of: "<|channel|>final", options: .backwards) else { return "" }
            var body = String(generated[final.upperBound...])
            for marker in ["<|return|>", "<|end|>", "<|call|>"] {
                if let end = body.range(of: marker) { body = String(body[..<end.lowerBound]) }
            }
            for header in ["<|constrain|>", "<|message|>"] {
                body = body.replacingOccurrences(of: header, with: "")
            }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Output tokens a reply may take beyond what its text needs. Harmony writes its
    /// analysis first, from the same budget, so it gets more room: a budget sized for
    /// the reply alone would end inside the analysis and leave no final channel at all.
    static func reasoningAllowance(_ family: ChatTemplateFamily) -> Int {
        family == .harmony ? 1024 : 0
    }

    /// Jinja's `trim`: whitespace and newlines off both ends.
    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `strftime_now("%Y-%m-%d")`, in the Mac's own time zone as llama-server's is.
    private static func harmonyDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Removes a leading `<think>…</think>` block.
///
/// A fallback, not the main defence: the local templates write an empty reasoning block
/// for the model, and the cloud clients ask for none. A model that reasons inline anyway
/// would defeat `TextRefinementService.parse` — the `<<mode:NAME>>` marker would no longer
/// lead, so the routing line would be pasted into the user's document along with the
/// model's private deliberation.
///
/// Only a *leading* block is removed, and only a closed one: text that merely contains
/// the word elsewhere is left alone, and an unterminated tag means the reply was cut off
/// rather than that it reasoned, so there is nothing safe to strip.
func strippingReasoning(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for tag in ["think", "thinking", "reasoning"] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard trimmed.hasPrefix(open), let end = trimmed.range(of: close) else { continue }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}
