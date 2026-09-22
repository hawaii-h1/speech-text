# Development

## Build

```bash
git clone https://github.com/yavno/speech-text.git
cd speech-text
open SpeechText/SpeechText.xcodeproj
```

Build with `Cmd+B`, run with `Cmd+R`. The first build resolves one Swift package, [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (pinned in `Package.resolved`), for local speech models; everything else is Apple frameworks.

### Code signing

The tracked project has an **empty `DEVELOPMENT_TEAM`** on purpose, so the repo builds for anyone who clones it. Xcode signs it locally ("Sign to Run Locally"), which is all you need for development.

Do **not** commit your team ID back into `project.pbxproj`. If Xcode adds it when you change a build setting, revert that hunk before committing. Release builds pass the team in at build time:

```bash
xcodebuild -project SpeechText/SpeechText.xcodeproj -scheme SpeechText \
  -configuration Release DEVELOPMENT_TEAM=XXXXXXXXXX build
```

### Hardened runtime

The app is built with the **hardened runtime** in both configurations, because notarization requires it, and a runtime restriction that only showed up in the notarized build would first be discovered by users. Everything the runtime would otherwise refuse is declared in `SpeechText/SpeechText.entitlements`:

| Entitlement | Used by |
|---|---|
| `com.apple.security.device.audio-input` | the microphone (`AVAudioEngine`) |
| `com.apple.security.automation.apple-events` | the AppleScript fallback that brings the target app back to the front before a paste (`PasteService.activateApp`) |

Accessibility (the ⌘V paste and reading the focused field) and speech recognition need no entitlement: macOS gates them through its privacy prompts alone. Adding a feature that touches another protected resource — the camera, location, the calendar, JIT-compiled code — means adding its entitlement here, or it fails only in signed builds. See [releasing.md](releasing.md) for how a release is signed and notarized.

## Hooks

```bash
git config core.hooksPath .githooks
```

Adds the DCO sign-off to every commit, and refuses one that carries a `DEVELOPMENT_TEAM`, a source file without the SPDX header, or a source file that is in no target. See [CONTRIBUTING.md](../CONTRIBUTING.md#hooks).

## Tests

```bash
xcodebuild test -project SpeechText/SpeechText.xcodeproj \
  -scheme SpeechText -destination 'platform=macOS'
```

The test bundle is **standalone** — no `TEST_HOST`, no `@testable import`. The app is a menu bar agent that asks for microphone access at launch, so hosting tests inside it would hang a headless run. Instead the test target compiles a curated subset of app sources directly.

**Consequence:** if your test needs a new app file, add that file to *both* targets' Sources phases. The same goes for anything it depends on. Files in the test subset must not reach into the app's view or state graph (SwiftUI views, `AppState`, `SpeechEngine`) — if they do, the subset stops being a subset.

Tests never touch `UserDefaults`: your real API keys live in that domain. Construct values directly instead.

## Pull requests

**Base every pull request on `main`.** CI refuses any other base, because a pull
request based on a branch merges into *that* branch — and if the branch has
already landed, the merge is green and the work never reaches `main`. That is
[#43](https://github.com/yavno/speech-text/issues/43): PR #41 merged into a
branch `main` had stopped following seven minutes earlier.

Stacking is still allowed where it earns its keep. Label the pull request
`stacked` and re-run the *Base branch* job; it then passes and prints which pull
request has to land first, and that this one must be retargeted at `main`
afterwards. The label is read live, so labelling a refused run and re-running the
job is enough — no new push. The job still refuses a stack whose base has already
merged, which is the #43 shape itself.

The audit that catches an evasion after the fact:

```bash
scripts/audit-merged-pull-requests.sh
```

It asks GitHub for every merged pull request and checks that each merge commit is
an ancestor of `origin/main`, exiting non-zero if any is not — or if any could not
be judged, since an unaudited pull request is not a clean one. Worth running
before a release and after any history rewrite.

A miss is permanent, which the script's `accounted_for` list exists for. A merge
commit that never reached `main` cannot be made an ancestor afterwards: the work
comes back as a *different* commit through a fresh pull request. PR #41 — the
case #43 was opened for — is therefore still outside `main` now that #43 is
closed, and will be every day after, even though #62 brought the work itself
back. It is the list's one entry, so the run prints it and stays green. Left out,
the audit would fail forever, and a check that always fails is a check nobody
reads.

## CI

`.github/workflows/ci.yml` runs on every pull request. **On a public repository
no job may run on the organisation's self-hosted Mac.** A pull request is code,
and anyone can open one; building and running it on someone's own Mac would hand
a stranger that machine's keychain, SSH keys and the app's `com.speechtext.app`
defaults domain, which is where the API keys live.

So every `runs-on` is keyed on the repository's visibility, and the flip is what
moves the work:

| Job | While private | Once public | What it does |
|---|---|---|---|
| Tests | `self-hosted` | `macos-latest` | `xcodebuild test` — the only job that needs a Mac |
| No development team | `self-hosted` | `ubuntu-latest` | greps `project.pbxproj` for a `DEVELOPMENT_TEAM` |
| SPDX headers | `self-hosted` | `ubuntu-latest` | the two-line header on every Swift file |
| DCO sign-off | `self-hosted` | `ubuntu-latest` | a `Signed-off-by` trailer on every commit in the range |
| Base branch | `self-hosted` | `ubuntu-latest` | the base is `main`, or the stack is labelled — see above |

While the repository is private only collaborators can open a pull request, so
the self-hosted Mac is the arrangement it has always been. The moment visibility
changes, every job moves by itself — nobody has to remember a second pull
request, and there is no window in which the arrangement is wrong. The polarity
is deliberate: an unrecognised visibility falls through to the hosted runner, so
the failure is a job that does not start rather than a stranger's code on
someone's Mac.

Actions minutes are free for a public repository on the standard runners. The
three cheap jobs then run on Linux, where they are faster and cost a tenth as
much, and stop competing for a runner with the tests.

A hosted runner starts empty, so WhisperKit, FluidAudio and Sparkle would be
cloned on every run. `-clonedSourcePackagesDirPath .swiftpm-cache` puts them
somewhere `actions/cache` can keep, keyed on the hash of `Package.resolved` —
which pins all three, so it is exactly the right key.

<!-- ci-timings -->
**Run time on a hosted runner: not yet measured.** As of 2026-09-22 this account
cannot start a GitHub-hosted runner at all — every such job fails in three
seconds with *"the job was not started because recent account payments have
failed or your spending limit needs to be increased"* — so the figure cannot be
taken while the repository is private. It becomes measurable the moment the
repository is public, since standard runners are then free, and the first
pull-request run after the flip belongs here. Do not anchor on the self-hosted
Mac's number: that build is warm and incremental (16 s on 2026-09-22), whereas a
hosted run resolves and builds all three Swift packages from nothing, which is
exactly what the cache above exists for.

The self-hosted Mac keeps the tag-triggered packaging in
[`release.yml`](../.github/workflows/release.yml), because that is where the
signing certificate lives and only someone who can push a tag can start it. That
workflow's pull-request trigger — the one that checks the packaging script still
works — is keyed on the event *and* the visibility, so on a public repository it
lands on `macos-latest` and never signs; the job's first step refuses outright
should a public repository's pull request reach the self-hosted runner anyway.


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
- **Services** (`PasteService`, `TextRefinementService`) are independent and testable.

## Style

Match the surrounding code. A few conventions the codebase holds to:

- Every source file opens with the two-line SPDX header (`SPDX-FileCopyrightText` / `SPDX-License-Identifier: GPL-3.0-or-later`).
- Comments explain *why*, not *what*. A measured constant gets a comment saying what it was measured against.
- Latency and quality constants live in `STTTuning`, not scattered across files.
- Use `dlog(category:message:)` for diagnostics — it goes to both the in-app Debug Log window and `os.Logger`.
- No new third-party dependencies. WhisperKit is the one exception and is imported only by `LocalWhisperRuntime.swift` — keep it there, because the test bundle compiles app sources directly and cannot resolve packages. If you think you need another dependency, open an issue first.
