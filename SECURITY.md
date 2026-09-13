# Security Policy

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Report privately via [GitHub Security Advisories](https://github.com/yavno/speech-text/security/advisories/new), or email the maintainer.

Expect a first response within 72 hours. Please include what you found, how to reproduce it, and what an attacker could do with it.

## What is in scope

SpeechText handles unusually sensitive things, so these matter most:

- **API keys** — leaking them through logs, crash reports, the debug log window, or any network request other than to the provider they belong to.
- **Audio and transcripts** — anything that sends recordings or transcribed text somewhere the user did not configure.
- **Accessibility and clipboard** — the app simulates `Cmd+V` and temporarily writes to the clipboard. Anything that leaves clipboard contents exposed, or pastes into the wrong target, is in scope.
- **Message delivery** — anything that could send a message without the user confirming it, or to the wrong recipient.
- **Contacts** — any read of the address book beyond resolving the recipient the user actually named.

## What is not in scope

- The privacy practices of Groq, ElevenLabs, OpenAI or Anthropic. You choose which provider to use; their terms apply to your data.
- Anything requiring an attacker to already have code execution as your user account.
- Missing hardening that has no demonstrable impact.

## Design notes

There is no SpeechText server. The app talks only to the providers you configured, with keys you supplied. There is no telemetry and no account.
