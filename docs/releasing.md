# Releasing

A release is a disk image that opens without a Gatekeeper warning: the app inside is
signed with a **Developer ID** certificate, built with the hardened runtime,
**notarized** by Apple and stapled, and so is the image around it. Nothing less
installs cleanly — since macOS Sequoia an unnotarized app can only be opened through
System Settings › Privacy & Security › Open Anyway, and Homebrew no longer accepts
casks that fail Gatekeeper.

The pipeline is `scripts/package-release.sh`, run by `.github/workflows/release.yml`
when a version tag is pushed. The certificate and notary credentials live only in
repository secrets (or your keychain); the tracked project keeps its empty
`DEVELOPMENT_TEAM`.

## Before the first public release: whose team signs it

The signature names a team, and **that team becomes part of the app's identity**.
macOS keys the Accessibility, microphone and speech-recognition grants to the code
signature's designated requirement, which includes the team ID. Moving to a different
team later re-asks every user for all of them — the same cost each rename of this app
has had. Pick the team that should own SpeechText for the long run before the first
image reaches anyone.

The team's name is what users see in the installer's and System Settings' "developer"
line, and the account holder is the one Apple holds responsible for what is signed.

## One-time setup

Everything here is done by someone with the right role on the Apple Developer account.

### 1. The Developer ID Application certificate

Only the **Account Holder** can create one.

1. On the Mac that will hold the private key: Xcode › Settings › Accounts › select the
   team › Manage Certificates… › **+** › *Developer ID Application*. (Or create a
   certificate signing request in Keychain Access and upload it at
   developer.apple.com › Certificates, IDs & Profiles › Certificates › **+**.)
2. In Keychain Access, find *Developer ID Application: … (TEAMID)*, expand it so the
   private key shows, select both, and **Export 2 items…** as a `.p12` with a strong
   password.

The `.p12` is the key to publishing software under that name. Keep it out of the
repository, chat and cloud folders; it goes into GitHub secrets and a password manager.

### 2. Credentials for the notary service

Prefer an **App Store Connect API key**: it is not anyone's password, it can be revoked
on its own, and it can be limited to the *Developer* role.

- App Store Connect › Users and Access › Integrations › App Store Connect API ›
  generate a key with the *Developer* role. Download the `.p8` (it can be downloaded
  only once) and note the **Key ID** and **Issuer ID**.

If the account offers no API keys, use an **app-specific password** instead:
account.apple.com › Sign-In and Security › App-Specific Passwords, together with the
Apple ID and the team ID.

### 3. Repository secrets

```bash
gh secret set DEVELOPER_ID_P12_BASE64   < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD             # prompts for the value

# API key:
gh secret set NOTARY_KEY_P8_BASE64      < <(base64 -i AuthKey_XXXXXXXXXX.p8)
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER_ID

# …or an Apple ID:
gh secret set NOTARY_APPLE_ID
gh secret set NOTARY_APP_PASSWORD
gh secret set NOTARY_TEAM_ID
```

## Cutting a release

1. Write what changed under `## [Unreleased]` in `CHANGELOG.md` as the work lands —
   that section becomes the release notes.
2. `.claude/skills/rebuild/scripts/rebuild.sh --tag X.Y.Z` sets the version, dates the
   CHANGELOG section, commits and tags `vX.Y.Z`. Nothing is pushed.
3. `git push && git push origin vX.Y.Z`.
4. The **Release** workflow checks the tag against the project version, signs,
   notarizes (a few minutes), and opens a **draft** release with
   `SpeechText-X.Y.Z.dmg` and its `.sha256`.
5. Download the image and install it on a Mac — or a fresh user account — that has
   never run SpeechText: it should open without any Gatekeeper dialog, and ask for the
   microphone, Accessibility and, on first use, speech recognition. Then publish the
   draft.

A tag pushed before the secrets exist fails the workflow instead of releasing an
unsigned image.

## Building a release locally

```bash
xcrun notarytool store-credentials speechtext-notary    # once; prompts for the credentials

SPT_DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
SPT_NOTARY_PROFILE=speechtext-notary \
scripts/package-release.sh
```

Run it without `SPT_DEVELOPER_ID` to exercise the packaging with no certificate at
all: it builds `SpeechText-X.Y.Z-unsigned.dmg`, signed ad-hoc and labelled as not for
distribution. `--from-app PATH` packages an app that is already built.

## When notarization fails

The script prints Apple's log for the rejected submission. The usual causes:

- **"The executable does not have the hardened runtime enabled"** — something nested
  was signed without `--options runtime`.
- **"The signature does not include a secure timestamp"** — `codesign` ran without
  network access to Apple's timestamp server.
- **get-task-allow** — a Debug build was packaged. The script refuses this before
  submitting.
- **A new protected resource** — a feature that uses one needs its entitlement in
  `SpeechText.entitlements` (see [development.md](development.md#hardened-runtime)),
  or it is refused at runtime rather than at notarization.
