# Development

## Build

```bash
git clone https://github.com/yavno/speech-text.git
cd speech-text
open SpeechText/SpeechText.xcodeproj
```

Build with `Cmd+B`, run with `Cmd+R`. The first build resolves three Swift packages, all pinned in `Package.resolved`: [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) and [FluidAudio](https://github.com/FluidInference/FluidAudio) for the two local speech engines and the voice activity detector, and [Sparkle](https://sparkle-project.org) for updates; everything else is Apple frameworks. FluidAudio declares Swift 6 tools, so it takes Xcode 16 or later.

Their licences — and those of the code each carries inside it — ship in the app as `Resources/ThirdPartyNotices.txt` (Settings › General › Acknowledgements). It is generated: after adding, removing or updating a package, run `scripts/third-party-notices.sh` and commit the result; `ThirdPartyNoticesTests` fails while the file names a version `Package.resolved` no longer pins.

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

Adds the DCO sign-off to every commit, and refuses one that carries a `DEVELOPMENT_TEAM`, a new Swift file without the SPDX header, or a new Swift file that is in no target. See [CONTRIBUTING.md](../CONTRIBUTING.md#hooks).

## Tests

```bash
xcodebuild test -project SpeechText/SpeechText.xcodeproj \
  -scheme SpeechText -destination 'platform=macOS'
```

The test bundle is **standalone** — no `TEST_HOST`, no `@testable import`. The app is a menu bar agent that asks for microphone access at launch, so hosting tests inside it would hang a headless run. Instead the test target compiles a curated subset of app sources directly.

**Consequence:** if your test needs a new app file, add that file to *both* targets' Sources phases. The same goes for anything it depends on. Files in the test subset must not reach into the app's view or state graph (SwiftUI views, `AppState`, `SpeechEngine`) — if they do, the subset stops being a subset.

Tests never touch `UserDefaults` or the keychain: your real settings live in that domain, and a build without the profile keeps your API keys there too. Construct values directly instead; `APIKeyStoreTests` gives the store an isolated `suiteName` and a keychain in memory.

## API keys

The API keys — one per provider that has one in `ProviderDescriptor`: Groq, ElevenLabs, OpenAI, Anthropic — are billing credentials, so they are not ordinary settings. `APIKeyStore` holds them in memory, and where they live on disk depends on how the build was signed:

- **Signed with the Developer ID provisioning profile** (releases, and `scripts/rebuild.sh` when the profile is in `~/.config/speech-text/`): the *data-protection keychain*, in the access group `TEAMID.app.speech-text.SpeechText`. Only code signed by this team with a profile that authorises the group can name it, so another process running as the user cannot read an item, with or without a prompt — unlike a plist, which any of them reads silently, and unlike the file-based login keychain, which asks the user and is one click away from saying yes. Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: tied to this Mac, never restored onto another. The group is fixed at `TEAMID.app.speech-text.SpeechText` rather than derived from the bundle identifier, so a future rename still finds the keys.
- **Without it** (Xcode ⌘R, a contributor's clone, a self-signed `SpeechText Dev` build): that keychain answers `errSecMissingEntitlement`, so the keys stay in UserDefaults, as they always did. A plist is not a store for secrets — mode `0600`, but readable by anything running as you and copied by every backup — which is why nothing distributed is built this way.

The mode is fixed at launch from the app's own signature (whether it carries `keychain-access-groups`), never from a failed call, so a passing keychain error cannot send a release's keys back into a plist. In keychain mode the first launch moves every key it finds — in the current domain first, then the pre-rename chain — writes it, reads it back, and only then deletes it from all four domains; a write that fails keeps every copy. A key found in the current domain *after* that is newer than the keychain's (a ⌘R build shares the domain) and replaces it.

The entitlements that name the group are **restricted**: signed without a profile that authorises them for this team, this app and this certificate, the app does not launch. So they are never in the tracked `SpeechText.entitlements`; `scripts/keychain-profile.sh` adds them only after checking all three, and `package-release.sh` refuses to make a distributable image without them. Setting the profile up is in [releasing.md](releasing.md#5-the-provisioning-profile).

Two costs follow. A change of Apple team makes the items unreachable, and every user enters their keys again (releasing.md says why the team is not expected to change). And a ⌘R build cannot see the keys a signed build moved — enter them there too, or sign ⌘R builds with an Apple Development profile of your own.

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

## Sign-off

Every commit you author carries a `Signed-off-by` trailer (see
[CONTRIBUTING.md](../CONTRIBUTING.md#signing-your-commits-dco)). The repository
settings take care of the rest:

- **Squash merging only.** Merge commits and rebase merging are off, so the merge
  button makes one commit on `main` per pull request and never a merge commit.
- **The squash message is the pull request's title and description.** GitHub
  appends the trailers of the commits being squashed, so the squash commit carries
  their `Signed-off-by`. Leave those lines in when you merge: the `dco` job checks
  the pull request's commits, and nothing checks the squash commit afterwards.
- **Head branches are deleted on merge**, so merged branches do not pile up.

The `dco` job fails a pull request with an unsigned commit. On this private
repository, though, that failure does not block anything: branch protection and
required checks need GitHub Pro or a public repository. A red *DCO sign-off* check
therefore means "do not merge", and pushing straight to `main` skips it
altogether.

### Known unsigned history

`main` holds 45 commits with no trailer: 42 from before squash-only, and three
squash commits since. None of them will be rewritten to add one: that would change
every hash after them. They are:

- **39 merge commits** made by the *Merge pull request* button, the last one
  `2b8a471` (PR #42, 2026-09-22). GitHub writes those itself and cannot add a
  trailer, and CI never sees them because they are made after the pull request's
  range. Squash-only removes this kind of commit.
- **Three ordinary commits**, all made after the `dco` job (2026-09-13) and the
  sign-off hook (2026-09-15) existed:
  - `ee3eeaf` *Document phase A completion and add offline test runner*
    (2026-09-16). It came in through PR #2, which was merged with its
    *DCO sign-off* check failing.
  - `9ff846e` *Add rebuild skill and build identity stamping* (2026-09-16), and
  - `9f82d63` *Move rebuild skill into user-run script and docs* (2026-09-17).
    Both were pushed straight to `main` with no pull request, so no check ran.
- **Three squash commits** — `a989b44` (PR #108, 2026-09-27), `a8e804e` (PR #131)
  and `cc9629c` (PR #132, both 2026-10-01) — merged with the message cut down to the
  title, which dropped the pull requests' `Signed-off-by` lines. This is the gap the
  bullet on the squash message warns about: nothing checks the squash commit itself.

  `ee3eeaf` and `9ff846e` are authored as `Vladyslav Husakov <vladhskv@gmail.com>`,
  and `9f82d63` as Vladyslav Husakov.

A script that counts unsigned commits on `main` should report exactly these 45.
If it finds any others, that is a new gap.

## CI

`.github/workflows/ci.yml` runs on every pull request. **On a public repository
no job may run on the organisation's self-hosted Mac.** A pull request is code,
and anyone can open one; building and running it on someone's own Mac would hand
a stranger that machine's keychain, SSH keys and the app's `app.speech-text.SpeechText`
defaults domain, which is where a build without the profile keeps the API keys.

So every `runs-on` is keyed on the repository's visibility, and the flip is what
moves the work:

| Job | While private | Once public | What it does |
|---|---|---|---|
| Tests | `self-hosted` | `macos-latest` | `xcodebuild test` — the only job that needs a Mac |
| No development team | `self-hosted` | `ubuntu-latest` | greps `project.pbxproj` for a `DEVELOPMENT_TEAM` |
| SPDX headers | `self-hosted` | `ubuntu-latest` | the two-line header on every Swift file |
| DCO sign-off | `self-hosted` | `ubuntu-latest` | a `Signed-off-by` trailer on every commit in the range |
| Provider guide | `self-hosted` | `ubuntu-latest` | `scripts/check-provider-guide.sh` — docs/adding-a-provider.md still names code that exists |
| Base branch | `self-hosted` | `ubuntu-latest` | the base is `main`, or the stack is labelled — see above |

While the repository is private only collaborators can open a pull request, so
the self-hosted Mac is the arrangement it has always been. The moment visibility
changes, every job moves by itself — nobody has to remember a second pull
request, and there is no window in which the arrangement is wrong. The polarity
is deliberate: an unrecognised visibility falls through to the hosted runner, so
the failure is a job that does not start rather than a stranger's code on
someone's Mac.

Actions minutes are free for a public repository on the standard runners. The
five cheap jobs then run on Linux, where they are faster and cost a tenth as
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
  testing-runs/        results of full passes of manual-testing.md
scripts/               rebuild, packaging, keychain profile, appcast, trace import
.githooks/             the sign-off and pre-commit hooks (see Hooks)
.github/workflows/     CI and the tag-triggered release
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
- Use `dlog("Category", "message")` for diagnostics — it goes to both the in-app Debug Log window and `os.Logger`.
- No new third-party dependencies. The three there are each imported by one file — WhisperKit by `LocalWhisperRuntime.swift`, FluidAudio by `LocalParakeetRuntime.swift` and `VoiceActivityRuntime.swift`, Sparkle by `UpdateChecker.swift` — keep them there, because the test bundle compiles app sources directly and cannot resolve packages. If you think you need another dependency, open an issue first.
