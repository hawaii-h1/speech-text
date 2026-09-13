# Development

## Build

```bash
git clone https://github.com/yavno/speech-text.git
cd speech-text
open SpeechText/SpeechText.xcodeproj
```

Build with `Cmd+B`, run with `Cmd+R`. No package manager, no dependencies — everything is Apple frameworks.

### Code signing

The tracked project has an **empty `DEVELOPMENT_TEAM`** on purpose, so the repo builds for anyone who clones it. Xcode signs it locally ("Sign to Run Locally"), which is all you need for development.

Do **not** commit your team ID back into `project.pbxproj`. If Xcode adds it when you change a build setting, revert that hunk before committing. Release builds pass the team in at build time:

```bash
xcodebuild -project SpeechText/SpeechText.xcodeproj -scheme SpeechText \
  -configuration Release DEVELOPMENT_TEAM=XXXXXXXXXX build
```

## Tests

```bash
xcodebuild test -project SpeechText/SpeechText.xcodeproj \
  -scheme SpeechText -destination 'platform=macOS'
```

The test bundle is **standalone** — no `TEST_HOST`, no `@testable import`. The app is a menu bar agent that asks for microphone access at launch, so hosting tests inside it would hang a headless run. Instead the test target compiles a curated subset of app sources directly.

**Consequence:** if your test needs a new app file, add that file to *both* targets' Sources phases. The same goes for anything it depends on. Files in the test subset must not reach into the app's view or state graph (SwiftUI views, `AppState`, `SpeechEngine`) — if they do, the subset stops being a subset.

Tests never touch `UserDefaults`: your real API keys live in that domain. Construct values directly instead.

## Project layout

```
SpeechText/
  SpeechText/          app sources
  SpeechTextTests/     unit tests
  SpeechText.xcodeproj
docs/
  development.md       this file
  specs/               design documents for larger features
CLAUDE.md              full architecture reference
```

## Architecture

[`CLAUDE.md`](../CLAUDE.md) is the detailed architecture reference — every component, the recognition tiers, the recording phase machine, the settings keys. It is written for AI coding agents but it is the most complete description of the codebase and worth reading before any non-trivial change.

The short version:

- **`SpeechEngine`** owns the microphone and the recording lifecycle. State lives in one `phase` value.
- **`RecognitionSession`** is the tier abstraction — one session per recorded segment. Three implementations: Apple on-device, batch upload, and realtime streaming (which falls back to batch when the stream breaks).
- **`AppState`** orchestrates the overlay, tracks the previously focused app, and pastes the result back.
- **Services** (`PasteService`, `WebhookService`, `MessageDelivery`, `ContactResolver`, `TextRefinementService`) are independent and testable.

## Style

Match the surrounding code. A few conventions the codebase holds to:

- Every source file opens with the two-line SPDX header (`SPDX-FileCopyrightText` / `SPDX-License-Identifier: GPL-3.0-or-later`).
- Comments explain *why*, not *what*. A measured constant gets a comment saying what it was measured against.
- Latency and quality constants live in `STTTuning`, not scattered across files.
- Use `dlog(category:message:)` for diagnostics — it goes to both the in-app Debug Log window and `os.Logger`.
- No third-party dependencies. If you think you need one, open an issue first.
