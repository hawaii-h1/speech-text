# Contributing to SpeechText

Contributions are welcome. This document exists so you never waste work on something that was never going to be merged.

## Before you write code

**Small fix?** Just open a PR. Typos, crashes, a wrong constant, a broken edge case — no ceremony needed.

**Anything bigger?** Open an issue first and wait for a reply. This includes new features, refactors, new settings, UI changes, and anything touching the recording pipeline. A PR that arrives without a prior issue may be closed even if the code is good, simply because it takes the project somewhere it isn't going.

Issues labelled [`good first issue`](../../labels/good%20first%20issue) and [`help wanted`](../../labels/help%20wanted) are pre-approved — take one and go.

## What is likely to be accepted

- Bug fixes, crash fixes, race conditions
- Accuracy or latency improvements with a measurement behind them
- New speech or LLM providers that fit the provider registry (`ProviderDescriptor`, see `docs/adding-a-provider.md`) — open an issue first (a new provider is a new place user data goes), then follow [docs/adding-a-provider.md](docs/adding-a-provider.md)
- Accessibility and localization work
- Test coverage for code that currently has none
- Documentation that fixes something wrong or missing

## What is unlikely to be accepted

- New third-party dependencies. The app is Apple frameworks plus WhisperKit and FluidAudio for local speech models and Sparkle for updates, each imported by one file, and each a deliberate decision — see ROADMAP.md.
- Large refactors that arrive unannounced
- Reformatting or restyling existing code
- Features that expand the product's scope without a prior discussion
- Anything that sends user data somewhere new

## Hooks

One command turns on the repo's git hooks, and the sign-off, the `DEVELOPMENT_TEAM` check and the SPDX header stop being things you have to remember:

```bash
git config core.hooksPath .githooks
```

- `prepare-commit-msg` adds the DCO `Signed-off-by` line to every commit, so `-s` is no longer something to forget.
- `pre-commit` refuses a commit that puts a `DEVELOPMENT_TEAM` back into `project.pbxproj`, adds a source file without the SPDX header, or adds a source file that is in no target. It reads the *staged* content and takes a fraction of a second; `--no-verify` bypasses it.

The test suite is deliberately not in a hook — CI runs it on every pull request, and a hook slow enough to avoid is a hook that gets bypassed.

## Signing your commits (DCO)

Every commit you author must carry a `Signed-off-by` line. Turn the hooks on (above) and it is added for you; otherwise Git adds it when asked:

```bash
git commit -s -m "Fix hotkey re-registration after sleep"
```

This is the [Developer Certificate of Origin](https://developercertificate.org/) — you are stating that you wrote the code, or otherwise have the right to submit it under the project's license. There is no CLA and you keep the copyright to your contribution.

That is a commitment, not a current convenience: no CLA will be introduced later, and the client will not be relicensed under closed terms. Your contribution stays yours, under GPL-3.0-or-later.

If you forget, `git commit --amend -s` fixes the last commit, and `git rebase --signoff main` fixes every commit on the branch.

Pull requests are merged as squashes — the only merge method the repository allows — so there is no merge commit to sign. The squash commit keeps the `Signed-off-by` trailers of the commits it replaces; when merging, leave them in the message.

## Pull request checklist

Short on purpose. Anything a machine can refuse for you is not on it:

- One concern per PR. Don't mix an unrelated fix into a feature.
- A new app file the tests need is in **both** targets' Sources phases (see [docs/development.md](docs/development.md)). CI does catch this, but as `cannot find 'X' in scope` in a test file — which reads like a missing import, not like a project file that was never told about your file.
- UI changes include a before/after screenshot. Anything with motion or timing includes a short video.
- The description says what changed and why.

Everything else is checked for you. CI runs the test suite (which compiles the app too), refuses a `DEVELOPMENT_TEAM` written back into `project.pbxproj`, refuses a Swift file without its SPDX header, fails when docs/adding-a-provider.md no longer matches the provider code, and requires a `Signed-off-by` on every commit in the pull request. The hooks above catch the same things before you push, except the provider guide, and add the sign-off itself.

## Language

Everything in the repository is written in English: code, comments, commit messages, pull requests, issues and documentation — the same language as the app's UI. Words in other languages appear only as data, such as a Ukrainian transcript a test or an explanation quotes. A few older documents predate this rule; one kept as a historical record says so at its top.

## Setting up

[docs/development.md](docs/development.md) covers building, testing and the project layout. [`CLAUDE.md`](CLAUDE.md) is the full architecture reference — read the relevant section before changing the recording pipeline.

## License

SpeechText is [GPLv3 or later](LICENSE), copyright (C) 2026 Vladyslav Husakov. By contributing you agree your work is published under it. You keep the copyright to your contribution — there is no CLA.

New source files start with the two-line SPDX header the rest of the codebase carries:

```swift
// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later
```

Substantial contributions may add their own `SPDX-FileCopyrightText` line below it.
