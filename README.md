# SpeechText

**Voice-to-text for macOS. Press a hotkey, speak, and the text appears where your cursor is.**

![CI](https://github.com/yavno/speech-text/actions/workflows/ci.yml/badge.svg)

Open source, bring your own API keys. A month of heavy dictation costs cents instead of a $15 subscription.

![SpeechText](speech-text.png)

---

## What it does

Hold a global hotkey, talk, release. SpeechText transcribes what you said and pastes it at the cursor in whatever app you were just using — your editor, a chat box, an email, anywhere.

**Three ways to use it:**

| Mode | Hotkey | What happens |
|---|---|---|
| **Inline** | `Ctrl+Shift+Q` | Speak → text is pasted at your cursor |
| **AI** | `Ctrl+Shift+A` | Speak → an LLM cleans it up → pasted at your cursor |
| **Record Window** | `Ctrl+Shift+W` | A floating panel for longer dictation you want to edit first |

All hotkeys are configurable.

### The dictation *is* the prompt

AI mode has no mode picker. You just talk, and the model figures out what you wanted from how you said it — clean up this text, write it as an email, translate it, turn it into a commit message. You define these as prompt presets, each with a plain-language "when to use this" description, and the model routes your dictation to the right one.

If the LLM fails or refuses, you still get your raw transcript. A dictation is never lost.

### Send it to someone

Optional, off by default. Say *"tell Oksana on Telegram that I'm running late"* and SpeechText resolves the name against your own Contacts and shows you a confirmation panel before anything is sent. Supports iMessage, Mail, Telegram and WhatsApp.

Nothing is ever sent without you confirming it.

---

## Speech engines

Pick per your priorities — all configurable in Settings:

| Engine | Cost | Notes |
|---|---|---|
| **Apple** (on-device) | free | Nothing leaves your Mac |
| **Groq** (Whisper) | ~$0.04/hour | Fast, accurate, needs an API key |
| **ElevenLabs** (Scribe v2) | pay-as-you-go | Realtime streaming, live partial text |
| **Whisper, local** | free | Open-source model downloaded to your Mac in one click; no key, works offline |

For local models, Settings reads your Mac's chip, memory and free disk, places it in a class from an 8 GB MacBook Neo to a 512 GB Mac Studio, and marks two models for it: a **recommended** one (the fastest of good quality) and a **best quality** one. Heavier models stay available, labelled.

For the AI pass you can use **Groq**, **Anthropic** or **OpenAI** with your own key — or run it locally through [Ollama](https://ollama.com), where Settings offers Qwen3.5 / 3.6 / 3.8, Gemma 4 and gpt-oss models from 1 GB to 81 GB, recommends a pair for your Mac, and downloads them in one click.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ to build
- Optional: API keys for the cloud engines you want to use
- Optional: [Ollama](https://ollama.com) for local AI processing

One Swift package — [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), for local speech models — resolved by Xcode on the first build. Everything else is Apple frameworks.

---

## Install

Signed release builds and a Homebrew cask are coming. For now, build from source:

```bash
git clone https://github.com/yavno/speech-text.git
cd speech-text
open SpeechText/SpeechText.xcodeproj
```

Then press `Cmd+R` in Xcode. See [docs/development.md](docs/development.md) for details.

### Permissions

macOS will ask for three permissions on first run. All three are required for the app to work:

- **Microphone** — to record you
- **Speech Recognition** — for the on-device Apple engine
- **Accessibility** — to paste at the cursor in other apps

The app runs as a menu bar agent with no dock icon and no main window.

---

## Privacy: where your audio goes

This matters, so it is stated plainly:

- **Apple engine** — audio never leaves your Mac.
- **Groq / ElevenLabs** — audio is uploaded to that provider, using *your* API key, under *their* privacy policy. SpeechText has no server and never sees your audio or your keys.
- **AI mode** — the transcript text (not the audio) is sent to the LLM provider you selected, with your key.
- **History** — transcripts are stored locally in `~/Library/Application Support/SpeechText/`. Failed recordings keep their audio for 7 days so you can retry, then it is deleted.
- **API keys** — stored in your local user defaults. Never transmitted anywhere except to the provider they belong to.

There is no telemetry, no analytics, and no account.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

Start with issues labelled [`good first issue`](https://github.com/yavno/speech-text/labels/good%20first%20issue). For anything larger, open an issue first so we can agree on the approach before you write code.

[ROADMAP.md](ROADMAP.md) describes where the project is heading, [CHANGELOG.md](CHANGELOG.md) what has already shipped, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) how we treat each other here.

---

## License

Copyright (C) 2026 Vladyslav Husakov

SpeechText is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either **version 3 of the License, or (at your option) any later version** — see [LICENSE](LICENSE).

In short: you can use, study, modify and redistribute SpeechText freely. If you distribute a modified version, you must publish your source under the same license.

Every source file carries an [SPDX](https://spdx.dev) header (`GPL-3.0-or-later`), so a file stays identifiable if it is ever copied out of the repository.

SpeechText will stay open source. There is no CLA, contributors keep the copyright to their work, and no future version will be relicensed under closed terms.
