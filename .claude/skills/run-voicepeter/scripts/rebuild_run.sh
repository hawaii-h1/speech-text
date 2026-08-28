#!/bin/bash
# Rebuild VoicePeter and restart it, replacing any running instance.
# Keeps the last few built .app bundles so a bad build can be rolled back.
#
# Usage: rebuild_run.sh [--release] [--no-launch]
#        rebuild_run.sh --list-backups
#        rebuild_run.sh --rollback [TIMESTAMP]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PROJECT="$REPO_ROOT/VoicePeter/VoicePeter.xcodeproj"
SCHEME="VoicePeter"
CONFIG="Debug"
LAUNCH=1
MODE="build"
ROLLBACK_TO=""
KEEP=3   # how many previous builds to retain (~4 MB each)

while [ $# -gt 0 ]; do
  case "$1" in
    --release)       CONFIG="Release" ;;
    --debug)         CONFIG="Debug" ;;
    --no-launch)     LAUNCH=0 ;;
    --list-backups)  MODE="list" ;;
    --rollback)
      MODE="rollback"
      # An optional timestamp may follow; anything starting with "-" is the next flag.
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then ROLLBACK_TO="$2"; shift; fi
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Fixed derived-data path. Two reasons this matters more than it looks:
# the .app lands at a predictable location we can `open`, and macOS keys the
# Accessibility (TCC) grant partly on the bundle path — a wandering path means
# re-granting permission in System Settings after every build.
DERIVED="$REPO_ROOT/build"
APP="$DERIVED/Build/Products/$CONFIG/VoicePeter.app"
BACKUPS="$DERIVED/backups/$CONFIG"

# --- helpers -----------------------------------------------------------------

# Quit the running app. Carbon's RegisterEventHotKey is system-wide, so a
# leftover instance keeps its claim on Ctrl+Shift+Q and races the new one.
stop_running() {
  if ! pgrep -x VoicePeter > /dev/null; then
    echo "No previous instance running."
    return 0
  fi
  osascript -e 'quit app "VoicePeter"' 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x VoicePeter > /dev/null || break
    sleep 0.3
  done
  pgrep -x VoicePeter > /dev/null && pkill -x VoicePeter
  sleep 0.3
  if pgrep -x VoicePeter > /dev/null; then
    echo "FAILED: could not stop the running VoicePeter (pid $(pgrep -x VoicePeter | tr '\n' ' '))" >&2
    exit 1
  fi
  echo "Stopped previous instance."
}

list_backups() {   # newest last
  ls -1d "$BACKUPS"/*/ 2>/dev/null | sort
}

launch_app() {
  open "$APP"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x VoicePeter > /dev/null && break
    sleep 0.3
  done
  if pgrep -x VoicePeter > /dev/null; then
    echo "Running: $APP (pid $(pgrep -x VoicePeter))"
    echo "It is a menu bar agent — no dock icon or window; look for the icon in the menu bar."
  else
    echo "FAILED: launched $APP but no VoicePeter process appeared." >&2
    exit 1
  fi
}

# --- mode: list ---------------------------------------------------------------
if [ "$MODE" = "list" ]; then
  found=$(list_backups)
  if [ -z "$found" ]; then
    echo "No backups yet for $CONFIG. One is saved each time the app is rebuilt."
    exit 0
  fi
  echo "Backups for $CONFIG (oldest first, keeping $KEEP):"
  echo "$found" | while read -r d; do
    stamp="$(basename "$d")"
    note=""
    [ -f "$d/.note" ] && note="  $(cat "$d/.note")"
    echo "  $stamp$note"
  done
  echo ""
  echo "Restore the newest with: rebuild_run.sh --rollback"
  echo "Or a specific one with:  rebuild_run.sh --rollback <TIMESTAMP>"
  exit 0
fi

# --- mode: rollback -----------------------------------------------------------
if [ "$MODE" = "rollback" ]; then
  if [ -n "$ROLLBACK_TO" ]; then
    SRC="$BACKUPS/$ROLLBACK_TO"
    if [ ! -d "$SRC/VoicePeter.app" ]; then
      echo "FAILED: no backup named '$ROLLBACK_TO' for $CONFIG." >&2
      echo "Run --list-backups to see what is available." >&2
      exit 1
    fi
  else
    SRC="$(list_backups | tail -1)"
    SRC="${SRC%/}"
    if [ -z "$SRC" ]; then
      echo "FAILED: no backups to roll back to." >&2
      echo "One is saved on each rebuild, so the first build has nothing behind it." >&2
      exit 1
    fi
  fi

  stop_running
  mkdir -p "$(dirname "$APP")"
  rm -rf "$APP"
  # ditto, not cp -R: it preserves the code signature and extended attributes,
  # and a restored bundle with a mangled signature will not launch.
  if ! ditto "$SRC/VoicePeter.app" "$APP"; then
    echo "FAILED: could not restore from $SRC" >&2
    exit 1
  fi
  echo "Restored $(basename "$SRC")$([ -f "$SRC/.note" ] && echo " ($(cat "$SRC/.note"))")."
  echo "Note: the source tree is unchanged — this swaps the binary only. The next"
  echo "rebuild overwrites it again, so use git to go back in the code as well."
  [ "$LAUNCH" -eq 1 ] && launch_app
  exit 0
fi

# --- mode: build --------------------------------------------------------------
stop_running

# Back up the bundle that is about to be replaced. Done before the build so the
# copy is the last version known to run, not a half-overwritten one.
if [ -d "$APP" ]; then
  exe="$APP/Contents/MacOS/VoicePeter"
  hash=$(shasum -a 256 "$exe" 2>/dev/null | cut -d' ' -f1)
  latest="$(list_backups | tail -1)"; latest="${latest%/}"
  if [ -n "$latest" ] && [ -f "$latest/.hash" ] && [ "$(cat "$latest/.hash")" = "$hash" ]; then
    # Rebuilding with no code change would otherwise push the last good build out
    # of the window with identical copies of itself — exactly when you need it.
    echo "Backup: current build already saved as $(basename "$latest")."
  else
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUPS/$stamp"
    if ditto "$APP" "$BACKUPS/$stamp/VoicePeter.app" 2>/dev/null; then
      echo "$hash" > "$BACKUPS/$stamp/.hash"
      git -C "$REPO_ROOT" log -1 --format='%h %s' > "$BACKUPS/$stamp/.note" 2>/dev/null
      echo "Backup: saved previous build as $stamp."
      # Prune oldest. BSD head has no negative -n, so compute the count.
      total=$(list_backups | wc -l | tr -d ' ')
      if [ "$total" -gt "$KEEP" ]; then
        list_backups | head -n $((total - KEEP)) | while read -r old; do rm -rf "$old"; done
      fi
    else
      # A failed backup is not a reason to block the build — say so and continue.
      echo "Backup: WARNING — could not copy previous build, continuing without it." >&2
    fi
  fi
fi

echo "Building $SCHEME ($CONFIG)..."
LOG="$(mktemp -t voicepeter-build)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build > "$LOG" 2>&1
STATUS=$?

if [ $STATUS -ne 0 ]; then
  echo ""
  echo "BUILD FAILED (exit $STATUS). Compiler diagnostics:"
  echo "---"
  grep -E "(error|warning):" "$LOG" | sed 's|'"$REPO_ROOT"'/||' | sort -u | head -40
  # Some failures (signing, missing scheme, plist) never produce an "error:" line,
  # so fall back to the tail rather than reporting an empty failure.
  if ! grep -qE "error:" "$LOG"; then
    echo "(no compiler errors — tail of build log:)"
    tail -25 "$LOG"
  fi
  echo "---"
  echo "Full log: $LOG"
  echo "The previous build is still installed and can be started with: --rollback"
  exit 1
fi

WARNINGS=$(grep -E "warning:" "$LOG" 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ "${WARNINGS:-0}" -gt 0 ]; then
  echo "Build succeeded ($WARNINGS warning$([ "$WARNINGS" -eq 1 ] || echo s))."
else
  echo "Build succeeded."
fi
rm -f "$LOG"

if [ ! -d "$APP" ]; then
  echo "FAILED: build reported success but $APP is missing." >&2
  exit 1
fi

if [ "$LAUNCH" -eq 0 ]; then
  echo "Skipping launch (--no-launch). App at: $APP"
  exit 0
fi

launch_app
