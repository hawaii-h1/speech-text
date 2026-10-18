# Security Policy

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Report privately via [GitHub Security Advisories](https://github.com/yavno/speech-text/security/advisories/new). That is the only reporting channel.

Expect a first response within 72 hours. Please include what you found, how to reproduce it, and what an attacker could do with it.

## What is in scope

SpeechText handles unusually sensitive things, so these matter most:

- **API keys** — leaking them through logs, crash reports, the debug log window, or any network request other than to the provider they belong to.
- **Audio and transcripts** — anything that sends recordings or transcribed text somewhere the user did not configure.
- **Accessibility and clipboard** — the app simulates `Cmd+V` and temporarily writes to the clipboard. Anything that leaves clipboard contents exposed, or pastes into the wrong target, is in scope.

## What is not in scope

- The privacy practices of Groq, ElevenLabs, OpenAI or Anthropic. You choose which provider to use; their terms apply to your data.
- Anything requiring an attacker to already have code execution as your user account.
- Missing hardening that has no demonstrable impact.

## Design notes

There is no SpeechText server. The app talks only to the providers you configured, with keys you supplied. There is no telemetry and no account.

**Where your API keys are kept.** A signed release keeps them in the macOS *data-protection keychain*, in an access group that only code signed by the SpeechText team can use. Another app running as you cannot read them, even if you click Allow. They are tied to this Mac and cannot be restored onto another one, so on a new Mac you enter them again. Keys that earlier versions kept in the preferences file are moved into the keychain on first launch and deleted from every preferences domain the app has used (`app.speech-text.SpeechText`, `com.speechtext.app`, `com.speachtext.app`, `com.voicepeter.app`). Older Time Machine snapshots still hold those files, so replacing the keys at the provider once after that move is worth doing.

What it does not protect against: software that already runs as you and can read the screen, the clipboard (a key is on it while you paste it into setup) or your keystrokes. A build made without the project's signing profile — an Xcode run or your own clone — cannot use that keychain and keeps the keys in its preferences file (`~/Library/Preferences/app.speech-text.SpeechText.plist`, readable by any process running as you), as 0.9.1 and earlier did. See [docs/development.md](docs/development.md#api-keys).

**What the log holds.** The Debug Log, and the copy of it every build writes to the macOS system log, records how long a dictation, selection or rewrite was, never its words, nor window titles or Dictionary terms. `scripts/check-log-privacy.sh` enforces this in CI. A vendor's error reply is logged as the vendor sent it.
