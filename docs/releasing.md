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

### 3. The update-signing key

SpeechText updates itself with [Sparkle](https://sparkle-project.org): the app reads an
**appcast** — an XML feed published as an asset of each release — and installs what it
finds there. What makes that download trustworthy is not Apple's certificate but an
**EdDSA key pair of our own**, and the two are deliberately independent: the Apple team
ID may change (converting the account to an organization would do it), and an update
signed with the same EdDSA key still installs.

Generate it once, on the maintainer's Mac. The private half stays in that Mac's Keychain:

```bash
scripts/make-appcast.sh --fetch-tools    # downloads Sparkle's tools into build/tools/
build/tools/sparkle-2.10.0/bin/generate_keys
```

It prints the **public** key. Put it in `SpeechText/SpeechText/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>…the printed key…</string>
```

Until that key is there the app simply has no updater: no menu item, no settings row,
nothing started at launch — and `scripts/package-release.sh` refuses to build a
distributable image at all, because an app that cannot be updated is not one to hand out.

A build from Xcode (⌘R) has no updater either, key or no key: it carries no commit and
build number 1, so it is older than every release, and every Sparkle setting lives in the
app's *own* defaults domain — which a ⌘R build shares with the copy in `/Applications`.
Updates are exercised from a `scripts/rebuild.sh` install.

The private half never goes in the repository. Export it for the CI secret and for a
password manager, then delete the file:

```bash
build/tools/sparkle-2.10.0/bin/generate_keys -x sparkle-private-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key.txt
rm sparkle-private-key.txt
```

Whoever holds this key can publish an update to every installed copy of SpeechText.
Losing it is survivable only the hard way: a new key means a new `SUPublicEDKey`, which
existing installs will not accept — everyone would have to download the next version by
hand. Keep a copy somewhere safe, and keep it out of everything else.

### 4. Repository secrets

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
   notarizes (a few minutes), writes the appcast, and opens a **draft** release with
   `SpeechText-X.Y.Z.dmg`, its `.sha256` and `appcast.xml`.
5. Download the image and install it on a Mac — or a fresh user account — that has
   never run SpeechText: it should open without any Gatekeeper dialog, and ask for the
   microphone, Accessibility and, on first use, speech recognition. Then publish the
   draft.
6. Check that the release it replaces can reach it: on a Mac running the *previous*
   version, SpeechText › Check for Updates… should offer this one, and installing it
   should leave the app running the new version with its permissions intact.

A tag pushed before the secrets exist fails the workflow instead of releasing an
unsigned image.

## How an installed copy learns about a new version

Every release carries `appcast.xml`, and the app reads it at
`…/releases/latest/download/appcast.xml` — a URL GitHub answers with the asset of
whatever release is currently the latest *published* one. So a draft release is invisible
to installed copies, and publishing the draft is the moment the update goes out. Sparkle
checks once a day; the menu item checks now.

The feed holds one item: the release being cut. Sparkle installs the best item it finds,
so one is enough, and it means a release depends on nothing from the release before it —
no archive of old disk images, no re-signing. The consequence to know about is that the
"what's new" text in the update window covers that version alone; the full history stays
in `CHANGELOG.md`, which the window links to.

A release taken back — unpublished or deleted — stops being offered: the `latest` URL
answers with the release before it again. Copies that already updated stay where they
are, so a bad version is pulled from everyone who has not updated yet, and fixed for the
rest by the next release.

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
