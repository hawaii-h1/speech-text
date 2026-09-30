# Roadmap

Where SpeechText is going. This is the contract with contributors: work that fits here is likely to be merged, work that doesn't should start as an issue.

Tracked work lives in [issues](../../issues). This file is the direction; issues are the tasks.

## Now

- **Distribution** — the signed, notarized `.dmg` and the in-app updater are in place, and 0.9.1 is packaged as a draft release; what is left is making the repository public, publishing that release, and a Homebrew cask. Until then the only way for anyone else to run SpeechText is to build it, which excludes almost everyone.
- **Accuracy for technical speech** — library names, identifiers and mixed-language dictation are where every engine struggles. The plan is a user dictionary that would feed its term list to the engine, to a post-transcription replacement table, and to the LLM prompt. None of it is built yet.

## Next

- **Notetaker** — record a conversation you are part of, then review a speaker-attributed transcript, summarise it, ask questions and export it. Microphone and system audio are captured as two separate tracks, so who-said-what is exact for a one-to-one conversation without any speaker model at all. See [the spec](docs/specs/2026-09-22-notetaker.md).
- **More providers** — behind the existing `STTProvider` / `LLMProvider` abstractions. New providers are a good contribution.
- **Localization** — the UI is English-only. Ukrainian first.

## Later

- **Sync** — presets and history across Macs.
- **Automation** — URL scheme, Shortcuts, a CLI, and an MCP server, so other tools can start a dictation or read a transcript.

## Done

Kept short, because a roadmap that never records an arrival stops being believed: continuous integration on every pull request; live transcription shown on the overlay while you speak and pasted once at the stop; local speech and chat models with a hardware-based recommendation; first-run setup; signed, notarized releases that update themselves; OpenAI as a speech engine; API keys in the keychain; dictations made offline saved and retried once the network is back.

## Not planned

Saying no early saves everyone time:

- **Third-party dependencies, beyond the three we have.** The app is Apple frameworks plus [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) and [FluidAudio](https://github.com/FluidInference/FluidAudio) for the two local speech engines, and [Sparkle](https://sparkle-project.org) for updates. Running Whisper needs a tokenizer and a decode loop that Core ML does not provide; running Parakeet needs a TDT decode loop and a mel frontend it does not provide either, and that model is smaller, faster and better on Ukrainian than any Whisper build we measured; updating an app outside the App Store needs a downloader, a signature check and an installer that can replace a running app, and getting that wrong breaks every user at once. Each is imported by exactly one file — `LocalWhisperRuntime.swift`, `LocalParakeetRuntime.swift` and `UpdateChecker.swift` — and everything else stays Apple-only.

  The bar is that boundary, not the count: a fourth dependency is fine if it earns its place the way these did — a measurement showing it beats what we have, and one file that names it. Anything that would be imported from three places across the app is the thing this rule is actually against.
- **iOS / iPadOS.** The whole design rests on pasting into another app on a desktop.
- **Windows / Linux.** Different project entirely.
- **A general audio-file transcription tool.** Dropping arbitrary podcasts, lectures or video rips in for text is someone else's product. Recording a conversation you are taking part in is not that, and is planned — see Notetaker above.
- **A meeting bot.** Something that joins a call as a participant needs a cloud, an account and a presence in someone else's meeting. Capture stays on this Mac.
- **Recording that starts by itself.** No calendar-triggered or call-detected capture, however often it is asked for: a recording that begins without a person starting it is the thing that consent rules exist about.
- **Telemetry or analytics of any kind.**

## Want to help?

Start with [`good first issue`](../../labels/good%20first%20issue). For anything on this roadmap, comment on the relevant issue first so two people don't build the same thing.
