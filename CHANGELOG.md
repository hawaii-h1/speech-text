# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-13

### Added

- Three recording modes: inline dictation pasted at the cursor, AI dictation rewritten by an LLM before pasting, and a Record Window for longer dictation you want to edit first — each on its own configurable global hotkey.
- Speech engines: Apple on-device (nothing leaves the Mac), Groq Whisper, and ElevenLabs Scribe — including realtime streaming with live partial text, which falls back to a batch upload of the same audio if the stream breaks.
- An LLM pass with prompt presets: the dictation itself is the prompt, and the model routes it to the preset whose "when to use" description matches. Groq, Anthropic and OpenAI are supported. Any failure or refusal falls back to the raw transcript.
- Message delivery (off by default): a dictation that names a person and a channel is resolved against your own Contacts and shown in a confirmation panel before anything is sent. iMessage, Mail, Telegram and WhatsApp.
- History of every transcription, stored locally, with retry from the archived audio for failed or empty results.
- Two skins — minimal and techno — covering the same features, with an optional accent colour for the minimal one.
- Webhook delivery: POST the transcribed text to a URL of your own, with optional Bearer token auth.
- Automatic language detection that follows the active macOS keyboard layout.

[Unreleased]: https://github.com/yavno/speech-text/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/yavno/speech-text/releases/tag/v1.0.0
