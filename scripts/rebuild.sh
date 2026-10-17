#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build SpeechText, install it to /Applications, and restart it there.
#
#   scripts/rebuild.sh                  build, install, launch
#   scripts/rebuild.sh --debug          Debug configuration instead of Release
#   scripts/rebuild.sh --no-launch      build and install, leave it stopped
#   scripts/rebuild.sh --status         what is installed, what is running, what HEAD is
#   scripts/rebuild.sh --list           the retained previous builds
#   scripts/rebuild.sh --rollback [ID]  reinstall the previous build (or a named one)
#   scripts/rebuild.sh --remove-legacy  move pre-rename installs to the Trash
#   scripts/rebuild.sh --tag X.Y.Z      cut a release: version, CHANGELOG, commit, tag
#
# The build runs *before* anything is stopped or replaced, so a build that fails
# leaves the app you are using untouched.

set -uo pipefail

APP_NAME="SpeechText"
BUNDLE_ID="app.speech-text.SpeechText"
# Every name this app has shipped under. Each is a separate bundle identifier with
# its own hotkey registration, so all of them have to be off the field.
LEGACY_NAMES=("SpeachText" "VoicePeter")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/$APP_NAME/$APP_NAME.xcodeproj"
SCHEME="$APP_NAME"
DERIVED="$REPO_ROOT/build"
INSTALLED="/Applications/$APP_NAME.app"
LEDGER="$DERIVED/installed.log"

# A code-signing certificate is what keeps the Accessibility grant alive across
# rebuilds. See docs/rebuild.md; override with the env var. Without one, a Developer ID
# certificate in the keychain is preferred to a self-made `SpeechText Dev`: it is the
# identity releases are signed with, so a grant made to a local build carries over to a
# release instead of being asked for again.
if [ -n "${SPT_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$SPT_SIGN_IDENTITY"
else
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:-SpeechText Dev}"
fi

CONFIG="Release"
LAUNCH=1
MODE="build"
ARG=""
KEEP=3

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)         CONFIG="Debug" ;;
        --release)       CONFIG="Release" ;;
        --no-launch)     LAUNCH=0 ;;
        --status)        MODE="status" ;;
        --list)          MODE="list" ;;
        --remove-legacy) MODE="remove-legacy" ;;
        --rollback)
            MODE="rollback"
            if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then ARG="$2"; shift; fi
            ;;
        --tag)
            MODE="tag"
            [ $# -gt 1 ] || { echo "--tag needs a version, e.g. --tag 0.10.0" >&2; exit 2; }
            ARG="$2"; shift
            ;;
        -h|--help)
            awk '/^# Build SpeechText/,0 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

BACKUPS="$DERIVED/backups/$CONFIG"

# --- small helpers ------------------------------------------------------------

die() { printf '%s\n' "$*" >&2; exit 1; }

plist_value() {  # plist_value <app> <key>
    # The existence check is not belt-and-braces: PlistBuddy answers a missing file
    # with "File Doesn't Exist, Will Create:" on *stdout*, which would otherwise be
    # read back as the version.
    [ -f "$1/Contents/Info.plist" ] || return 1
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

# The one-line identity of a built bundle, in the same shape the menu bar shows.
stamp_of() {  # stamp_of <app>
    local app="$1" short build commit date parts
    [ -d "$app" ] || { echo "(not installed)"; return; }
    short="$(plist_value "$app" CFBundleShortVersionString)"
    build="$(plist_value "$app" CFBundleVersion)"
    commit="$(plist_value "$app" SPTGitCommit)"
    date="$(plist_value "$app" SPTBuildDate)"
    case "$commit" in ''|'$('*) echo "${short:-?} (unstamped — built by Xcode, not by this script)"; return ;; esac
    parts="build ${build:-?} · $commit"
    [ -n "$date" ] && parts="$parts · $date"
    echo "${short:-?} ($parts)"
}

running_pids() {  # every instance of every name this app has had
    local name
    for name in "$APP_NAME" "${LEGACY_NAMES[@]}"; do
        pgrep -x "$name" 2>/dev/null
    done
}

stop_all() {
    local name pid stopped=0
    for name in "$APP_NAME" "${LEGACY_NAMES[@]}"; do
        pgrep -x "$name" > /dev/null 2>&1 || continue
        osascript -e "quit app \"$name\"" > /dev/null 2>&1
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "$name" > /dev/null 2>&1 || break
            sleep 0.3
        done
        pgrep -x "$name" > /dev/null 2>&1 && pkill -x "$name"
        sleep 0.3
        if pgrep -x "$name" > /dev/null 2>&1; then
            pid="$(pgrep -x "$name" | tr '\n' ' ')"
            die "FAILED: could not stop $name (pid $pid). Quit it from the menu bar and run again."
        fi
        echo "  stopped $name"
        stopped=1
    done
    [ "$stopped" -eq 0 ] && echo "  nothing was running"
    return 0
}

# Sets LAUNCH_PROBLEM and returns 1 instead of exiting, so a failed launch still
# ends in the summary rather than cutting it off.
LAUNCH_PROBLEM=""
launch_app() {
    open "$INSTALLED" || { LAUNCH_PROBLEM="macOS refused to open $INSTALLED"; echo "  FAILED: $LAUNCH_PROBLEM" >&2; return 1; }
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" > /dev/null 2>&1 && break
        sleep 0.3
    done
    local pid
    pid="$(pgrep -x "$APP_NAME" | head -1)"
    if [ -z "$pid" ]; then
        LAUNCH_PROBLEM="it was opened, but no $APP_NAME process appeared"
        echo "  FAILED: $LAUNCH_PROBLEM" >&2
        return 1
    fi
    # The point of installing to a fixed path is that this can be asserted: a copy
    # running from DerivedData or from an old bundle would show the old behaviour
    # while the build log said success.
    local path
    path="$(ps -o comm= -p "$pid")"
    case "$path" in
        "$INSTALLED"/*) : ;;
        *)
            LAUNCH_PROBLEM="the running $APP_NAME is $path, not the one just installed"
            echo "  FAILED: $LAUNCH_PROBLEM" >&2
            return 1
            ;;
    esac
    echo "  running: pid $pid from $INSTALLED"
}

list_backups() { ls -1d "$BACKUPS"/*/ 2>/dev/null | sort; }

# A build's identity in words rather than in stamp shorthand, for the summary.
version_words() {  # version_words <app>
    local app="$1" short build commit date words
    [ -d "$app" ] || { echo "nothing"; return; }
    short="$(plist_value "$app" CFBundleShortVersionString)"
    build="$(plist_value "$app" CFBundleVersion)"
    commit="$(plist_value "$app" SPTGitCommit)"
    date="$(plist_value "$app" SPTBuildDate)"
    case "$commit" in
        ''|'$('*) echo "version ${short:-?} (no build stamp — built from Xcode)"; return ;;
    esac
    words="version ${short:-?}, build ${build:-?}, commit ${commit%+}"
    case "$commit" in *+) words="$words + uncommitted changes" ;; esac
    [ -n "$date" ] && words="$words, built $date"
    echo "$words"
}

# The last thing every build or rollback prints: what happened, in plain words, and
# where the app actually is. Everything above it is the log; this is the answer.
#   print_summary <ok|failed> <headline> [detail lines...]
print_summary() {
    local outcome="$1" headline="$2" mark line pid path
    shift 2
    [ "$outcome" = "ok" ] && mark="✓" || mark="✗"

    echo ""
    echo "════════════════════════════ SUMMARY ════════════════════════════"
    echo "  $mark $headline"
    for line in "$@"; do echo "  $line"; done
    echo ""
    echo "  Installed:  $(version_words "$INSTALLED")"
    echo "  App:        $INSTALLED"
    [ -d "$INSTALLED" ] || echo "              (this path does not exist)"

    local pids
    pids="$(running_pids)"
    if [ -z "$pids" ]; then
        echo "  Running:    no"
    else
        for pid in $pids; do
            path="$(ps -o comm= -p "$pid" 2>/dev/null)"
            path="${path%/Contents/MacOS/*}"
            if [ "$path" = "$INSTALLED" ]; then
                echo "  Running:    yes (pid $pid)"
            else
                # The case the summary exists for: something other than the app just
                # installed is what answers the hotkey.
                echo "  Running:    a DIFFERENT copy (pid $pid): $path"
            fi
        done
    fi

    if [ -d "$INSTALLED" ]; then
        case "$(codesign -d --requirements - "$INSTALLED" 2>&1)" in
            *"certificate leaf"*) echo "  Signing:    stable — Accessibility permission survives rebuilds" ;;
            *)                    echo "  Signing:    ad-hoc — if paste stops working, re-enable SpeechText in" \
                                  && echo "              System Settings › Privacy & Security › Accessibility" ;;
        esac
    fi

    local name
    for name in "${LEGACY_NAMES[@]}"; do
        [ -d "/Applications/$name.app" ] && echo "  Old copy:   /Applications/$name.app is still there (remove: scripts/rebuild.sh --remove-legacy)"
    done
    echo "═════════════════════════════════════════════════════════════════"
}

check_license() {
    local out
    out="$(xcodebuild -project "$PROJECT" -list 2>&1)"
    case "$out" in
        *"not agreed to the Xcode license"*)
            echo "xcodebuild is blocked by the Xcode licence agreement." >&2
            echo "" >&2
            echo "Xcode's GUI licence was accepted for an older version than the one installed," >&2
            echo "so the command-line tool refuses to run. Accept it once, in a terminal:" >&2
            echo "" >&2
            echo "    sudo xcodebuild -license accept" >&2
            echo "" >&2
            echo "It asks for your password, which is why this script cannot do it for you." >&2
            exit 1
            ;;
    esac
}

# --- mode: status -------------------------------------------------------------

if [ "$MODE" = "status" ]; then
    echo "installed:  $INSTALLED"
    echo "            $(stamp_of "$INSTALLED")"
    head_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
    dirty=""
    git -C "$REPO_ROOT" diff --quiet 2>/dev/null || dirty=" (uncommitted changes)"
    git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null || dirty=" (uncommitted changes)"
    echo "HEAD:       $head_commit$dirty"
    if [ ! -d "$INSTALLED" ]; then
        echo "            — nothing is installed there yet; run scripts/rebuild.sh"
    else
        installed_commit="$(plist_value "$INSTALLED" SPTGitCommit)"
        case "$installed_commit" in
            "$head_commit"*) echo "            ✓ the installed build is this commit" ;;
            ''|'$('*)        echo "            ? the installed build carries no stamp (built by Xcode, not by this script)" ;;
            *)               echo "            ✗ the installed build is $installed_commit, not HEAD" ;;
        esac
    fi

    pids="$(running_pids)"
    if [ -n "$pids" ]; then
        echo "running:"
        for pid in $pids; do echo "            pid $pid  $(ps -o comm= -p "$pid")"; done
    else
        echo "running:    nothing"
    fi

    for name in "${LEGACY_NAMES[@]}"; do
        [ -d "/Applications/$name.app" ] && echo "legacy:     /Applications/$name.app is still installed (--remove-legacy)"
    done

    if [ -f "$LEDGER" ]; then
        echo ""
        echo "last installs:"
        tail -5 "$LEDGER" | sed 's/^/            /'
    fi
    exit 0
fi

# --- mode: list ---------------------------------------------------------------

if [ "$MODE" = "list" ]; then
    found="$(list_backups)"
    [ -n "$found" ] || { echo "No backups yet for $CONFIG. One is kept each time a new build replaces the installed app."; exit 0; }
    echo "Backups for $CONFIG (oldest first, keeping $KEEP):"
    echo "$found" | while read -r d; do
        stamp="$(basename "$d")"
        note=""
        [ -f "$d/.note" ] && note="  $(cat "$d/.note")"
        echo "  $stamp$note"
    done
    echo ""
    echo "Reinstall the newest with:  scripts/rebuild.sh --rollback"
    echo "Or a specific one with:     scripts/rebuild.sh --rollback <ID>"
    exit 0
fi

# --- mode: remove-legacy ------------------------------------------------------

if [ "$MODE" = "remove-legacy" ]; then
    moved=0
    for name in "${LEGACY_NAMES[@]}"; do
        src="/Applications/$name.app"
        [ -d "$src" ] || continue
        pgrep -x "$name" > /dev/null 2>&1 && { echo "Stopping $name..."; stop_all; }
        # To the Trash, not rm -rf: this is the user's working install until the new
        # one has proved itself, and a Trash can be opened again.
        dest="$HOME/.Trash/$name-$(date +%Y%m%d-%H%M%S).app"
        if mv "$src" "$dest"; then
            echo "Moved $src to the Trash."
            moved=1
        else
            echo "FAILED to move $src" >&2
        fi
    done
    [ "$moved" -eq 0 ] && echo "No pre-rename installs found."
    if [ "$moved" -eq 1 ]; then
        echo ""
        echo "If the old one was a login item, clear it in System Settings › General ›"
        echo "Login Items — the new app registers itself separately."
    fi
    exit 0
fi

# --- mode: rollback -----------------------------------------------------------

if [ "$MODE" = "rollback" ]; then
    if [ -n "$ARG" ]; then
        SRC="$BACKUPS/$ARG"
        [ -d "$SRC/$APP_NAME.app" ] || die "FAILED: no backup '$ARG' for $CONFIG. Run --list to see what there is."
    else
        SRC="$(list_backups | tail -1)"; SRC="${SRC%/}"
        [ -n "$SRC" ] || die "FAILED: no backups to roll back to. One is kept on each install, so the first has nothing behind it."
    fi
    WAS="$(version_words "$INSTALLED")"
    echo "Stopping:"
    stop_all
    rm -rf "$INSTALLED"
    # ditto, not cp -R: it preserves the code signature and extended attributes, and
    # a restored bundle with a broken seal will not launch.
    if ! ditto "$SRC/$APP_NAME.app" "$INSTALLED"; then
        print_summary failed "Rollback FAILED: could not copy the backup into place" \
            "Backup: $SRC" "Nothing is installed at the path below until this is fixed."
        exit 1
    fi
    echo "Restored $(basename "$SRC")."
    if [ "$LAUNCH" -eq 1 ]; then
        echo "Launching:"
        if ! launch_app; then
            print_summary failed "Rolled back, but the app did NOT start: $LAUNCH_PROBLEM" "Replaced: $WAS"
            exit 1
        fi
        headline="Rolled back to backup $(basename "$SRC") and started it"
    else
        headline="Rolled back to backup $(basename "$SRC") (not started: --no-launch)"
    fi
    print_summary ok "$headline" "Replaced: $WAS" "Your source code was not touched — only the installed app changed."
    exit 0
fi

# --- mode: tag ----------------------------------------------------------------

if [ "$MODE" = "tag" ]; then
    case "$ARG" in
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) die "FAILED: '$ARG' is not a X.Y.Z version." ;;
    esac
    cd "$REPO_ROOT" || die "FAILED: no $REPO_ROOT"
    git diff --quiet && git diff --cached --quiet || die "FAILED: the working tree has uncommitted changes. A release tag has to name a commit that exists."
    git rev-parse -q --verify "refs/tags/v$ARG" > /dev/null && die "FAILED: tag v$ARG already exists."

    pbxproj="$APP_NAME/$APP_NAME.xcodeproj/project.pbxproj"
    previous="$(grep -m1 -o 'MARKETING_VERSION = [^;]*' "$pbxproj" | sed 's/MARKETING_VERSION = //')"
    [ -n "$previous" ] || die "FAILED: could not read MARKETING_VERSION from $pbxproj"
    today="$(date +%Y-%m-%d)"

    sed -i '' "s/MARKETING_VERSION = $previous;/MARKETING_VERSION = $ARG;/g" "$pbxproj"

    # The version the new section compares against is whichever one the link block
    # already lists first — read it before rewriting, because the rewrite inserts a
    # line that would otherwise be the one found.
    prevtag="$(grep -m1 -oE '^\[[0-9]+\.[0-9]+\.[0-9]+\]:' CHANGELOG.md | tr -d '[]:')"
    [ -n "$prevtag" ] || die "FAILED: CHANGELOG.md has no previous version link to compare against."

    # Move what is under [Unreleased] into a dated section of its own and re-point
    # the compare links. Everything written under the heading is carried over
    # verbatim; only the heading and the link lines are touched.
    awk -v ver="$ARG" -v day="$today" -v prevtag="$prevtag" '
        /^## \[Unreleased\]/ && !seen { print; print ""; print "## [" ver "] - " day; seen = 1; next }
        /^\[Unreleased\]: / {
            line = $0
            sub(/compare\/v[0-9.]+\.\.\.HEAD/, "compare/v" ver "...HEAD", line)
            print line
            print "[" ver "]: https://github.com/yavno/speech-text/compare/v" prevtag "...v" ver
            next
        }
        { print }
    ' CHANGELOG.md > CHANGELOG.md.new && mv CHANGELOG.md.new CHANGELOG.md

    git add "$pbxproj" CHANGELOG.md
    git commit -s -m "Release $ARG" || die "FAILED: the release commit was refused (see the hook output above)."
    git tag -a "v$ARG" -m "SpeechText $ARG" || die "FAILED: could not create tag v$ARG"

    echo "Tagged v$ARG ($previous → $ARG). Nothing was pushed."
    echo "  review:  git show v$ARG"
    echo "  publish: git push && git push origin v$ARG"
    echo "  install: scripts/rebuild.sh"
    exit 0
fi

# --- mode: build --------------------------------------------------------------

check_license
[ -d "$PROJECT" ] || die "FAILED: no Xcode project at $PROJECT"

COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
    # A "+" is the whole warning: what ran is not any commit, so a bug found in it
    # cannot be reproduced from git alone.
    COMMIT="$COMMIT+"
fi
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

# Signing. An ad-hoc signature is pinned to the binary's hash, so every rebuild is a
# different app as far as TCC is concerned and the Accessibility grant is dropped —
# the paste then silently stops working. A certificate makes the signature stable.
#
# The certificate is applied *after* the build with codesign, not handed to Xcode:
# Xcode's manual signing rejects a self-signed certificate as untrusted, and
# `find-identity -v` hides one for the same reason — so the lookup omits -v too.
HAVE_IDENTITY=0
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
    HAVE_IDENTITY=1
    echo "Will sign with \"$SIGN_IDENTITY\"."
else
    echo "Signing ad-hoc — no \"$SIGN_IDENTITY\" certificate in the keychain."
    echo "  macOS may drop the Accessibility grant after this build; docs/rebuild.md says how to fix that for good."
fi

echo "Building $SCHEME ($CONFIG) from $COMMIT..."
LOG="$(mktemp -t speech-text-build)"
echo "  (takes a minute or two; to follow along: tail -f $LOG)"
BUILD_STARTED=$SECONDS
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SPT_GIT_COMMIT="$COMMIT" \
    SPT_BUILD_DATE="$BUILD_DATE" \
    build > "$LOG" 2>&1
STATUS=$?
BUILD_SECONDS=$((SECONDS - BUILD_STARTED))

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"

if [ $STATUS -ne 0 ] || [ ! -d "$BUILT" ]; then
    echo ""
    echo "BUILD FAILED (exit $STATUS). Diagnostics:"
    echo "---"
    grep -E "(error|warning):" "$LOG" | sed "s|$REPO_ROOT/||" | sort -u | head -40
    if ! grep -qE "error:" "$LOG"; then
        echo "(no compiler errors — tail of the build log:)"
        tail -25 "$LOG"
    fi
    echo "---"
    print_summary failed "Build FAILED — nothing was changed" \
        "The errors are listed above." \
        "Full log: $LOG"
    exit 1
fi

WARNINGS=$(grep -E "warning:" "$LOG" 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ "${WARNINGS:-0}" -gt 0 ]; then
    echo "Build succeeded in ${BUILD_SECONDS}s ($WARNINGS warning$([ "$WARNINGS" -eq 1 ] || echo s))."
else
    echo "Build succeeded in ${BUILD_SECONDS}s."
fi
rm -f "$LOG"

# The stamp is worth nothing if the placeholders did not expand — a key renamed in
# Info.plist and not here would fail exactly this way, silently.
BUILT_COMMIT="$(plist_value "$BUILT" SPTGitCommit)"
if [ "$BUILT_COMMIT" != "$COMMIT" ]; then
    echo "WARNING: the build stamp did not take (Info.plist says '${BUILT_COMMIT:-empty}', expected '$COMMIT')." >&2
    echo "         The app will show 'dev' in the menu bar. Check the SPT_GIT_COMMIT key in Info.plist." >&2
fi

# Library validation. The app is built with the hardened runtime, which lets it load only
# frameworks signed by its own team — and Sparkle is a framework. A certificate with a team
# ID (Developer ID, Apple Development) satisfies that once the framework is re-signed with
# it; an ad-hoc signature or a self-made certificate has no team at all, and dyld refuses
# Sparkle even when every piece is signed the same way ("mapping process and mapped file
# have different Team IDs"). Both measured on 2026-09-18: the app died before drawing
# anything. So a teamless local build gets `disable-library-validation` added to *its own*
# signature — this script's installs only; package-release.sh, which makes what users
# get, never adds it.
HAS_TEAM=0
if [ "$HAVE_IDENTITY" -eq 1 ] && printf '%s' "$SIGN_IDENTITY" | grep -qE '\([A-Z0-9]{10}\)$'; then
    HAS_TEAM=1
fi

# Sparkle's framework and the helpers inside it, and the SpeechTextLLM service with the
# llama.framework inside *it*, deepest first — Xcode left them ad-hoc, and the app's
# signature only seals them.
nested_dirs() {
    local dir
    for dir in "$BUILT/Contents/Frameworks" "$BUILT/Contents/XPCServices"; do
        [ -d "$dir" ] && printf '%s\n' "$dir"
    done
}

sign_nested() {
    local nested dirs=()
    while IFS= read -r dir; do dirs+=("$dir"); done < <(nested_dirs)
    [ "${#dirs[@]}" -gt 0 ] || return 0
    while IFS= read -r -d '' nested; do
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$nested" || return 1
    done < <(find "${dirs[@]}" -depth \
        \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.app' \
           -o -name '*.xpc' -o -name 'Autoupdate' \) -print0)
}

# The keychain. With the Developer ID provisioning profile (docs/releasing.md) a team
# build is signed for the data-protection keychain, where the API keys live; without it
# the app keeps them in UserDefaults. keychain-profile.sh embeds the profile only when it
# matches the certificate, because a mismatch is an app that never launches.
source "$REPO_ROOT/scripts/keychain-profile.sh"
PROFILE="${SPT_PROVISIONING_PROFILE:-$DEFAULT_PROVISIONING_PROFILE}"
KEYCHAIN_SIGNED=0

sign_local() {
    if [ "$HAVE_IDENTITY" -eq 1 ]; then
        sign_nested || return 1
    fi
    if [ "$HAS_TEAM" -eq 1 ] &&
        prepare_keychain_signing "$BUILT" "$SIGN_IDENTITY" "$PROFILE" \
            "$REPO_ROOT/$APP_NAME/$APP_NAME/$APP_NAME.entitlements" "$LOG.keychain.plist"; then
        # The tracked entitlements plus the keychain group, not Xcode's: they are the
        # ones a release is signed with.
        codesign --force --sign "$SIGN_IDENTITY" --options runtime \
            --entitlements "$LOG.keychain.plist" "$BUILT" || return 1
        rm -f "$LOG.keychain.plist"
        KEYCHAIN_SIGNED=1
    elif [ "$HAS_TEAM" -eq 1 ]; then
        # Keep the entitlements Xcode signed in (sandbox off), regenerate everything
        # else so the designated requirement names the certificate rather than a hash.
        codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements,flags "$BUILT" || return 1
    else
        local entitlements="$LOG.entitlements.plist" as="-"
        [ "$HAVE_IDENTITY" -eq 1 ] && as="$SIGN_IDENTITY"
        codesign -d --entitlements - --xml "$BUILT" > "$entitlements" 2>/dev/null || return 1
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
            "$entitlements" || return 1
        # The LLM service loads llama.framework, which no team signed either.
        local service="$BUILT/Contents/XPCServices/SpeechTextLLM.xpc" service_entitlements="$LOG.llm-entitlements.plist"
        if [ -d "$service" ]; then
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
                "$service_entitlements" > /dev/null || return 1
            codesign --force --sign "$as" --options runtime --entitlements "$service_entitlements" "$service" || return 1
            rm -f "$service_entitlements"
        fi
        codesign --force --sign "$as" --options runtime --entitlements "$entitlements" "$BUILT" || return 1
        rm -f "$entitlements"
    fi
    codesign --verify --deep --strict "$BUILT"
}

if ! sign_local > "$LOG.sign" 2>&1; then
    if [ "$HAVE_IDENTITY" -eq 1 ]; then
        echo "FAILED: could not sign with \"$SIGN_IDENTITY\":" >&2
    else
        echo "FAILED: could not re-sign the ad-hoc build:" >&2
    fi
    sed 's/^/  /' "$LOG.sign" >&2
    print_summary failed "Signing FAILED — nothing was changed" \
        "If macOS asked for keychain access and it was denied, run again and choose Always Allow."
    exit 1
fi
rm -f "$LOG.sign"
if [ "$KEYCHAIN_SIGNED" -eq 1 ]; then
    echo "Signed for the keychain: API keys are kept there."
else
    echo "Not signed for the keychain (${KEYCHAIN_SKIP_REASON:-no team certificate}): API keys stay in UserDefaults."
fi

echo "Stopping:"
stop_all

# Keep the bundle that is about to be replaced. Done after the build so it is only
# paid for when there is something to replace it with.
if [ -d "$INSTALLED" ]; then
    hash="$(shasum -a 256 "$INSTALLED/Contents/MacOS/$APP_NAME" 2>/dev/null | cut -d' ' -f1)"
    latest="$(list_backups | tail -1)"; latest="${latest%/}"
    if [ -n "$latest" ] && [ -f "$latest/.hash" ] && [ "$(cat "$latest/.hash")" = "$hash" ]; then
        echo "Backup: the installed build is already saved as $(basename "$latest")."
    else
        stamp="$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUPS/$stamp"
        if ditto "$INSTALLED" "$BACKUPS/$stamp/$APP_NAME.app" 2>/dev/null; then
            echo "$hash" > "$BACKUPS/$stamp/.hash"
            stamp_of "$INSTALLED" > "$BACKUPS/$stamp/.note"
            echo "Backup: kept the outgoing build as $stamp."
            total=$(list_backups | wc -l | tr -d ' ')
            if [ "$total" -gt "$KEEP" ]; then
                list_backups | head -n $((total - KEEP)) | while read -r old; do rm -rf "$old"; done
            fi
        else
            echo "Backup: WARNING — could not copy the installed build, continuing without it." >&2
        fi
    fi
fi

WAS_WORDS="$(version_words "$INSTALLED")"
[ "$WAS_WORDS" = "nothing" ] && WAS_WORDS="nothing (first install)"

rm -rf "$INSTALLED"
if ! ditto "$BUILT" "$INSTALLED"; then
    print_summary failed "Install FAILED: could not copy the new build to /Applications" \
        "The new build is at: $BUILT" \
        "Restore the previous one with: scripts/rebuild.sh --rollback"
    exit 1
fi
NOW="$(stamp_of "$INSTALLED")"

mkdir -p "$DERIVED"
printf '%s  %s  %s\n' "$BUILD_DATE" "$CONFIG" "$NOW" >> "$LEDGER"

stamp_note=""
[ "$BUILT_COMMIT" = "$COMMIT" ] || stamp_note="Warning: the version stamp did not take, so the menu will say (dev)."

if [ "$LAUNCH" -eq 1 ]; then
    echo "Launching:"
    if ! launch_app; then
        print_summary failed "Built and installed, but the app did NOT start: $LAUNCH_PROBLEM" \
            "Replaced:   $WAS_WORDS" ${stamp_note:+"$stamp_note"}
        exit 1
    fi
    headline="Built, installed and started"
else
    headline="Built and installed (not started: --no-launch)"
fi

print_summary ok "$headline" \
    "Replaced:   $WAS_WORDS" \
    "Check it:   the first line of the menu bar menu shows the version below" \
    ${stamp_note:+"$stamp_note"}
