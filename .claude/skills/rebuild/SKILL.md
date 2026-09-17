---
name: rebuild
description: Build SpeechText, install it to /Applications and restart it there, keeping the previous build for rollback. Use when the user runs /rebuild, or asks to rebuild, reinstall, relaunch, restart, roll back, check which build is running, or cut a release tag.
user-invokable: true
disable-model-invocation: true
allowed-tools: Bash, Read, Grep
---

# Rebuild and reinstall SpeechText

```bash
.claude/skills/rebuild/scripts/rebuild.sh
```

Run it from anywhere; it finds the repository root itself. One command builds the
current source, replaces `/Applications/SpeechText.app`, and starts it.

| Option | Effect |
|---|---|
| *(none)* | Build Release, install, launch |
| `--debug` | Debug configuration instead (backups are kept per configuration) |
| `--no-launch` | Build and install, leave it stopped |
| `--status` | What is installed, what is running, whether either is HEAD |
| `--list` | The retained previous builds |
| `--rollback [ID]` | Reinstall the previous build, or a named one, and launch it |
| `--remove-legacy` | Move `SpeachText.app` / `VoicePeter.app` to the Trash |
| `--tag X.Y.Z` | Cut a release: version, CHANGELOG, commit, annotated tag |

The script prints one line per stage and exits non-zero on failure, then ends every
build and rollback — successful or not — with a **SUMMARY** block: what happened, the
version now installed and the one it replaced, the app's path, whether it is running
and from where (a copy running from anywhere else is called out), the signing, and any
pre-rename copy still in `/Applications`. That block is the answer; relay it to the
user in plain words. Open the build log only when the summary points you at one.

## Two things to do once, before the first run

**1. Accept the Xcode licence.** Xcode's GUI licence was agreed for an older version
than the one installed, and `xcodebuild` refuses to run until the terminal one is
too. It needs a password, so the script cannot do it:

```bash
sudo xcodebuild -license accept
```

The script checks this first and stops with that instruction rather than producing a
confusing build failure.

**2. Make a code-signing certificate.** Without one the app is signed *ad-hoc*, and
an ad-hoc signature is pinned to the binary's hash: to macOS, every rebuild is a
different application, so the Accessibility grant is dropped and paste-back silently
stops working until you toggle SpeechText off and on in System Settings. A
certificate makes the signature stable, and the grant then survives every rebuild.

In **Keychain Access** → menu **Keychain Access › Certificate Assistant › Create a
Certificate…**:

- Name: `SpeechText Dev`
- Identity Type: *Self Signed Root*
- Certificate Type: **Code Signing**
- leave "Let me override defaults" off, Create, Done

That is all — no need to mark it trusted. Xcode still builds with its usual local
signature; the script then re-signs the finished bundle with this certificate using
`codesign` directly, because Xcode's own manual signing rejects a self-signed
certificate as untrusted. The first time, macOS asks whether `codesign` may use the
key: choose **Always Allow**. Run with `SPT_SIGN_IDENTITY="Other Name"` if you named
yours differently. Whichever way it
went, the last line of a successful run says which you got:

```
  sign:  stable (identity-based)
  sign:  ad-hoc (Accessibility may need re-granting)
```

It reads that from the built bundle's designated requirement rather than from what
it asked for, so it reports what actually happened.

## Which build is running

Every build is stamped with the commit it came from, and the menu bar's first line
shows it:

```
SpeechText 1.0 (build 47 · a18a7d1 · 2026-09-16 14:20)
```

`1.0` is the release version from CHANGELOG.md and only moves on `--tag`. `build 47`
is the commit count, `a18a7d1` the commit — with a trailing `+` when the working
tree had uncommitted changes, which is the whole warning: what ran is not any commit,
so a bug found in it cannot be reproduced from git alone. Clicking the line copies it,
for pasting into an issue.

The stamp is passed on the `xcodebuild` line into `$(SPT_GIT_COMMIT)` /
`$(SPT_BUILD_DATE)` placeholders in `Info.plist`. A plain Xcode ⌘R build defines
neither, so the menu says `1.0 (dev)` — which is the honest answer for a build that
was never recorded, not a bug. `--status` compares the installed stamp against HEAD
and says whether they agree.

## Why the app is installed to /Applications rather than run from the build directory

Two grants depend on where the bundle lives. macOS keys Accessibility partly on the
path, and a login item registered from a `build/` directory points at something that
a `git clean` deletes. A fixed install path also makes one check possible that is
otherwise guesswork: after launching, the script asserts that the running process
really is the one under `/Applications/SpeechText.app`. Without that, a stray copy
elsewhere goes on showing the old behaviour while the build log says success.

## Why everything is stopped first

SpeechText registers its global shortcuts through Carbon's `RegisterEventHotKey`,
which is system-wide. A leftover instance keeps its claim on `⌃⇧Q`, so two copies
compete and the dictation lands in whichever one won. The symptom is confusing — the
app "sometimes ignores the hotkey" — and the cause is invisible, because a menu bar
agent has no dock icon to reveal that two are running.

The script stops **every name the app has shipped under** — `SpeechText`,
`SpeachText`, `VoicePeter` — not just the current one. They are three different
bundle identifiers with three separate registrations, so stopping only the current
name leaves exactly the race this is meant to prevent.

The stop happens **after** a successful build, not before it. A build that fails
therefore leaves the app you were using running and installed; there is nothing to
roll back to.

## The first run replaces a pre-rename install

`/Applications/SpeachText.app` is the app under its misspelled name, and it is a
different bundle identifier. Installing the correctly-spelled one:

- fires the two one-shot migrations (`adoptPreRenameStore`, `adoptPreRenameDefaults`)
  that carry history, API keys, shortcuts and presets across — **once**, on the first
  launch that finds them;
- re-asks for microphone, speech recognition and accessibility, because macOS keys
  those to the bundle identifier;
- registers itself as a login item, since `hasRegisteredLaunchAtLogin` deliberately
  does not migrate.

The old bundle is left in place — it is the working install until the new one has
proved itself, and it holds the grants. Once the new one works, `--remove-legacy`
moves it to the Trash (not `rm -rf`, so it can be fished back out), and the old login
item is worth clearing in System Settings › General › Login Items, or two agents
start at every boot.

## Backups and rollback

Before each install the outgoing `/Applications/SpeechText.app` is copied to
`build/backups/<config>/<timestamp>/` with the stamp it carried. The last three are
kept (~4 MB each). Only the built bundle is saved, never the source — the source is
in git, and a second source-history mechanism would drift out of step with it.

What this buys you is the case git cannot cover on its own: a change that compiles and
then misbehaves at runtime. `--rollback` puts the last working binary back without
waiting for a rebuild, which matters because this app's failure modes — hotkeys,
microphone, paste-back — only appear when it is actually running.

- **A rebuild with no code change does not consume a slot.** The script compares the
  executable's hash against the newest backup and skips an identical copy. Without
  that, building a few times while debugging something unrelated would quietly push
  the last good version out of a three-deep window, precisely when you need it.
- **Rollback swaps the binary only.** The working tree still holds the code that
  produced the bad build. Going back in the source as well is a git operation; the
  script deliberately does not touch your files.

## Cutting a release

```bash
.claude/skills/rebuild/scripts/rebuild.sh --tag 1.1.0
```

Requires a clean working tree. It sets `MARKETING_VERSION` in `project.pbxproj`, moves
everything under CHANGELOG's `## [Unreleased]` into a dated `## [1.1.0]` section,
re-points the compare links, commits with a DCO sign-off and creates the annotated tag
`v1.1.0`. **Nothing is pushed** — it prints the push command and leaves the decision
to you. Run the script again afterwards to install the build that now says `1.1.0`.

Pushing the tag is what publishes: the **Release** workflow signs and notarizes the
build and opens a *draft* GitHub release with the disk image, which a person then
checks and publishes. That needs the Developer ID secrets; without them the workflow
fails instead of releasing an unsigned image. See `docs/releasing.md`.

It never writes release notes. What goes under `[Unreleased]` is written by hand as
the work happens; a generated summary of commit subjects is not a changelog.

## Reading the result

**Build failed.** The script prints the deduplicated `error:`/`warning:` lines and the
log path. Fix the code and run the script again rather than re-reading the log — a
second run gives you the current errors, and stale diagnostics from a partial build
are a common way to chase a bug that is already fixed.

**Built and launched.** There is no window to look at: the app is `LSUIElement`, so it
lives only in the menu bar. Report the summary's `Replaced` / `Installed` lines and let the user drive it
— the features are hotkey- and microphone-based, so you cannot exercise them yourself.
If the change is worth checking, say what to press (`⌃⇧Q` inline, `⌃⇧A` AI, `⌃⇧W`
record window) and what they should see.

## When something looks wrong after a successful launch

- **The menu shows an older version than you expected.** The stamp does not lie;
  `--status` will say the same. Either the build did not come from HEAD, or something
  other than `/Applications/SpeechText.app` is running — the launch check should have
  caught the second, so suspect the first.
- **The hotkeys do nothing, or paste stops working.** Accessibility permission. If
  the run reported `sign: ad-hoc`, that is the cause and the certificate above is the
  fix. Otherwise toggle SpeechText off and on in System Settings › Privacy & Security
  › Accessibility. It cannot be fixed from code.
- **Settings look wrong, or a picker is blank.** Provider and model choices live in
  UserDefaults under `com.speechtext.app` and survive reinstalls, so a stale stored
  value can outlive the code that understood it. `defaults read com.speechtext.app`
  shows the state. `defaults delete com.speechtext.app` resets everything **including
  the user's API keys** — ask before doing that.
- **Old behaviour persists after a successful launch.** Check `--status`. A second
  copy under a legacy name may still be running and answering the hotkey first.
