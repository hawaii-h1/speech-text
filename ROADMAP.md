# Roadmap

Where SpeechText is going. This is the contract with contributors: work that fits here is likely to be merged, work that doesn't should start as an issue.

Tracked work lives in [issues](../../issues). This file is the direction; issues are the tasks.

## Now

- **Distribution** — signed and notarized `.dmg`, GitHub Releases, Homebrew cask, in-app auto-update. Today the only way to run SpeechText is to build it, which excludes almost everyone.
- **CI** — build and test on every PR.
- **Latency** — chunked transcription so text appears while you are still speaking. See [the spec](docs/specs/2026-08-29-low-latency-chunked-transcription.md).

## Next

- **Accuracy for technical speech** — library names, identifiers and mixed-language dictation are where every engine struggles.
- **More providers** — behind the existing `STTProvider` / `LLMProvider` abstractions. New providers are a good contribution.
- **Localization** — the UI is English-only. Ukrainian first.
- **Onboarding** — first-run setup is currently "go create accounts and paste keys".

## Later

- **Sync** — presets and history across Macs.

## Not planned

Saying no early saves everyone time:

- **Third-party dependencies.** The app is pure Apple frameworks.
- **iOS / iPadOS.** The whole design rests on pasting into another app on a desktop.
- **Windows / Linux.** Different project entirely.
- **A general audio-file transcription tool.** That is a different kind of app. SpeechText is about dictation into the cursor.
- **Telemetry or analytics of any kind.**

## Want to help?

Start with [`good first issue`](../../labels/good%20first%20issue). For anything on this roadmap, comment on the relevant issue first so two people don't build the same thing.
