# Contributing to SpeechText

Contributions are welcome. This document exists so you never waste work on something that was never going to be merged.

## Before you write code

**Small fix?** Just open a PR. Typos, crashes, a wrong constant, a broken edge case — no ceremony needed.

**Anything bigger?** Open an issue first and wait for a reply. This includes new features, refactors, new settings, UI changes, and anything touching the recording pipeline. A PR that arrives without a prior issue may be closed even if the code is good, simply because it takes the project somewhere it isn't going.

Issues labelled [`good first issue`](../../labels/good%20first%20issue) and [`help wanted`](../../labels/help%20wanted) are pre-approved — take one and go.

## What is likely to be accepted

- Bug fixes, crash fixes, race conditions
- Accuracy or latency improvements with a measurement behind them
- New speech or LLM providers that fit the existing `STTProvider` / `LLMProvider` abstractions
- Accessibility and localization work
- Test coverage for code that currently has none
- Documentation that fixes something wrong or missing

## What is unlikely to be accepted

- Third-party dependencies. The app is pure Apple frameworks and stays that way.
- Large refactors that arrive unannounced
- Reformatting or restyling existing code
- Features that expand the product's scope without a prior discussion
- Anything that sends user data somewhere new

## Signing your commits (DCO)

Every commit must carry a `Signed-off-by` line. Git adds it for you:

```bash
git commit -s -m "Fix hotkey re-registration after sleep"
```

This is the [Developer Certificate of Origin](https://developercertificate.org/) — you are stating that you wrote the code, or otherwise have the right to submit it under the project's license. There is no CLA and you keep the copyright to your contribution.

If you forget, `git commit --amend -s` fixes the last commit.

## Pull request checklist

- One concern per PR. Don't mix an unrelated fix into a feature.
- `xcodebuild test -project SpeechText/SpeechText.xcodeproj -scheme SpeechText -destination 'platform=macOS'` passes.
- New app files needed by tests are added to **both** targets (see [docs/development.md](docs/development.md)).
- `DEVELOPMENT_TEAM` in `project.pbxproj` is still empty — Xcode likes to put yours back in.
- UI changes include a before/after screenshot. Anything with motion or timing includes a short video.
- The description says what changed and why.

## Setting up

[docs/development.md](docs/development.md) covers building, testing and the project layout. [`CLAUDE.md`](CLAUDE.md) is the full architecture reference — read the relevant section before changing the recording pipeline.

## License

SpeechText is [GPLv3](LICENSE). By contributing you agree your work is published under it.
