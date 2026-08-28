---
name: run-voicepeter
description: Rebuild the VoicePeter macOS app and restart it, stopping any instance that is already running and keeping the previous build for rollback. Use when the user runs /run-voicepeter, or asks to rebuild, relaunch, restart, roll back, or "try" the app after a code change.
user-invokable: true
disable-model-invocation: true
allowed-tools: Bash, Read, Grep
---

# Rebuild and run VoicePeter

One command that replaces the running app with a fresh build:

```bash
.claude/skills/run-voicepeter/scripts/rebuild_run.sh
```

Run it from the repository root. Options:

| Option | Effect |
|---|---|
| `--release` | Build Release instead of Debug (backups are kept per configuration) |
| `--no-launch` | Build and verify only — useful when you just want to know whether it compiles |
| `--list-backups` | Show the retained previous builds |
| `--rollback [STAMP]` | Reinstall the previous build, or a specific one, and launch it |

The script quits the running instance, saves the outgoing `.app`, builds the
`VoicePeter` scheme into `build/`, and launches the result. It prints one line per
stage and exits non-zero on failure, so its output is the whole story — you don't
need to inspect the build log unless it points you at one.

## Why the stop-first step is not optional

VoicePeter registers its global shortcuts through Carbon's `RegisterEventHotKey`,
which is process-wide and system-wide. A leftover instance keeps its registration
alive, so two copies compete for `Ctrl+Shift+Q` and the dictation lands in
whichever one happened to win. The symptom is confusing — the app "sometimes
ignores the hotkey" — and the cause is invisible, because it's a menu bar agent
with no dock icon to reveal that two are running. So the script always clears the
field before building.

## Backups and rollback

Before each build the current `.app` is copied to `build/backups/<config>/<timestamp>/`,
along with the HEAD commit line it was built from. The last three are kept (~4 MB
each). Only the built bundle is saved, not the source — the source is already in
git, and a second source-history mechanism would just drift out of step with it.

What this buys you is the case git can't cover on its own: a change that compiles
and then misbehaves at runtime. `--rollback` puts the last working binary back
without waiting for a rebuild, which matters because the app's failure modes
(hotkeys, microphone, paste-back) only show up when it's actually running.

Two properties worth knowing when reasoning about the backups:

- **A rebuild with no code change doesn't consume a slot.** The script compares the
  executable's hash against the newest backup and skips identical copies. Without
  that, running the build a few times while debugging something unrelated would
  quietly push the last good version out of a three-deep window — precisely when
  you'd reach for it.
- **Rollback swaps the binary only.** The working tree still holds the code that
  produced the bad build. If you want to go back in the source as well, that's a
  git operation; the script deliberately doesn't touch your files.

## Reading the result

**Build failed.** The script prints the deduplicated `error:`/`warning:` lines and
the log path. Fix the code and run the script again rather than re-reading the
log — a second run gives you the current errors, and stale diagnostics from a
partial build are a common way to chase a bug that's already fixed. The previously
installed app is untouched by a failed build, so `--rollback` is only needed if you
also want to *run* the old version while you work.

**Built and launched.** There's no window to look at: the app is `LSUIElement`, so
it lives only in the menu bar. Report that it's running and let the user drive it —
the features are hotkey- and microphone-based, so you can't exercise them yourself.
If the change is worth checking, tell the user what to press (`Ctrl+Shift+Q` inline,
`Ctrl+Shift+A` AI, `Ctrl+Shift+W` record window) and what they should see.

## When something looks wrong after a successful launch

- **The hotkeys do nothing, or paste stops working.** Accessibility permission is
  tied to the app's code signature, which changes on every build. macOS usually
  carries the grant over, but when it doesn't, the fix is in System Settings ›
  Privacy & Security › Accessibility: toggle VoicePeter off and on again. It
  cannot be fixed from code.
- **Settings look wrong or a picker is blank.** The app persists provider/model
  choices in UserDefaults under `com.voicepeter.app`, and those survive rebuilds —
  a stale stored value can outlive the code that understood it. `defaults read
  com.voicepeter.app` shows the current state; `defaults delete com.voicepeter.app`
  resets everything, including the user's API keys, so ask before doing that.
- **The build succeeds but old behaviour persists.** Confirm the launched binary
  is the one just built: `pgrep -lx VoicePeter` should show a path under `build/`.
  A copy installed elsewhere (for instance in `/Applications`) will otherwise be
  the one the user is actually looking at.
