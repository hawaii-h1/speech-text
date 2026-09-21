# Roadmap

Where SpeechText is going. This is the contract with contributors: work that fits here is likely to be merged, work that doesn't should start as an issue.

Tracked work lives in [issues](../../issues). This file is the direction; issues are the tasks.

## Now

- **Distribution** — signed and notarized `.dmg` on GitHub Releases with in-app auto-update, and a Homebrew cask. Today the only way to run SpeechText is to build it, which excludes almost everyone.
- **CI** — build and test on every PR.
- **Latency** — chunked transcription so text appears while you are still speaking. See [the spec](docs/specs/2026-08-29-low-latency-chunked-transcription.md).

## Next

- **Accuracy for technical speech** — library names, identifiers and mixed-language dictation are where every engine struggles.
- **More providers** — behind the existing `STTProvider` / `LLMProvider` abstractions. New providers are a good contribution.
- **Localization** — the UI is English-only. Ukrainian first.
- **Onboarding** — first-run setup is currently "go create accounts and paste keys". The building blocks exist: local speech models install in one click with a hardware-based recommendation, and local AI runs through Ollama. What is missing is the first-run flow that asks "local or cloud?" and walks through it.

## Later

- **Sync** — presets and history across Macs.

## Not planned

Saying no early saves everyone time:

- **Third-party dependencies, beyond the two we have.** The app is Apple frameworks plus [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for local speech models and [Sparkle](https://sparkle-project.org) for updates. Running Whisper needs a tokenizer and a decode loop that Core ML does not provide; updating an app outside the App Store needs a downloader, a signature check and an installer that can replace a running app, and getting that wrong breaks every user at once. Each is imported by exactly one file — `LocalWhisperRuntime.swift` and `UpdateChecker.swift` — and everything else stays Apple-only. A third dependency needs an issue first.
- **iOS / iPadOS.** The whole design rests on pasting into another app on a desktop.
- **Windows / Linux.** Different project entirely.
- **A general audio-file transcription tool.** Other apps do that well. SpeechText is about dictation into the cursor.
- **Telemetry or analytics of any kind.**

## Want to help?

Start with [`good first issue`](../../labels/good%20first%20issue). For anything on this roadmap, comment on the relevant issue first so two people don't build the same thing.
