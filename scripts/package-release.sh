#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build SpeechText for distribution: sign it with a Developer ID, notarize it, and
# wrap it in a notarized disk image that opens without a Gatekeeper warning.
#
#   package-release.sh                    build Release from HEAD and package it
#   package-release.sh --from-app PATH    package an app that is already built
#   package-release.sh --out DIR          where the .dmg goes (default build/release)
#
# Signing and notarization come from the environment, so nothing secret is ever in
# the repository:
#
#   SPT_DEVELOPER_ID      "Developer ID Application: Name (TEAMID)"
#
#   and one way to reach the notary service —
#   SPT_NOTARY_PROFILE    a profile saved with `xcrun notarytool store-credentials`
#   SPT_NOTARY_KEY        path to an App Store Connect API key (.p8), with
#   SPT_NOTARY_KEY_ID     its key ID, and
#   SPT_NOTARY_ISSUER     its issuer ID (omit for an individual API key)
#   SPT_NOTARY_APPLE_ID   an Apple ID, with
#   SPT_NOTARY_PASSWORD   an app-specific password for it, and
#   SPT_NOTARY_TEAM_ID    the team ID
#
#   SPT_PROVISIONING_PROFILE  the Developer ID provisioning profile that lets the app keep
#                         its API keys in the data-protection keychain (default:
#                         ~/.config/speech-text/SpeechText_Developer_ID.provisionprofile).
#                         A distributable image is refused without it.
#
# The disk image window is laid out by dmgbuild (scripts/dmg/), installed from PyPI into a
# throwaway virtual environment, pinned by hash. It needs Python 3.10 or later: whatever
# SPT_PYTHON names, else the first of `python3`, `python3.14` … `python3.10` on PATH that is
# new enough (the Command Line Tools' `python3` is 3.9).
#
# Without SPT_DEVELOPER_ID it still builds a disk image — signed ad-hoc and labelled
# as not for distribution — so the packaging itself can be exercised by anyone.
# Gatekeeper blocks that image on every Mac but the one that built it.

set -euo pipefail

APP_NAME="SpeechText"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/$APP_NAME/$APP_NAME.xcodeproj"
ENTITLEMENTS="$REPO_ROOT/$APP_NAME/$APP_NAME/$APP_NAME.entitlements"

OUT="$REPO_ROOT/build/release"
FROM_APP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="$2"; shift ;;
        --from-app) FROM_APP="$2"; shift ;;
        -h|--help)
            awk '/^# Build SpeechText for distribution/,0 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

IDENTITY="${SPT_DEVELOPER_ID:-}"
DISTRIBUTABLE=0
[ -n "$IDENTITY" ] && DISTRIBUTABLE=1

# --- notary credentials -----------------------------------------------------------

NOTARY_ARGS=()
if [ -n "${SPT_NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$SPT_NOTARY_PROFILE")
elif [ -n "${SPT_NOTARY_KEY:-}" ]; then
    [ -n "${SPT_NOTARY_KEY_ID:-}" ] || die "SPT_NOTARY_KEY is set but SPT_NOTARY_KEY_ID is not"
    NOTARY_ARGS=(--key "$SPT_NOTARY_KEY" --key-id "$SPT_NOTARY_KEY_ID")
    [ -n "${SPT_NOTARY_ISSUER:-}" ] && NOTARY_ARGS+=(--issuer "$SPT_NOTARY_ISSUER")
elif [ -n "${SPT_NOTARY_APPLE_ID:-}" ]; then
    [ -n "${SPT_NOTARY_PASSWORD:-}" ] && [ -n "${SPT_NOTARY_TEAM_ID:-}" ] \
        || die "SPT_NOTARY_APPLE_ID needs SPT_NOTARY_PASSWORD and SPT_NOTARY_TEAM_ID"
    NOTARY_ARGS=(--apple-id "$SPT_NOTARY_APPLE_ID" --password "$SPT_NOTARY_PASSWORD" --team-id "$SPT_NOTARY_TEAM_ID")
fi

if [ "$DISTRIBUTABLE" -eq 1 ] && [ ${#NOTARY_ARGS[@]} -eq 0 ]; then
    # A Developer ID signature without notarization is still blocked by Gatekeeper,
    # so producing one would only look like a release.
    die "SPT_DEVELOPER_ID is set but no notary credentials are (see the header of this script)"
fi

# --- version and stamp --------------------------------------------------------------

VERSION="$(sed -n 's/.*MARKETING_VERSION = \([0-9][0-9.]*\);.*/\1/p' "$PROJECT/project.pbxproj" | head -1)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from project.pbxproj"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

if [ -z "$FROM_APP" ] && ! { git -C "$REPO_ROOT" diff --quiet && git -C "$REPO_ROOT" diff --cached --quiet; }; then
    # What users download has to be a commit: a bug reported against it must be
    # reproducible from git.
    [ "$DISTRIBUTABLE" -eq 0 ] || die "the working tree has uncommitted changes; a release is built from a commit"
    COMMIT="$COMMIT+"
fi

WORK="$(mktemp -d -t speech-text-release)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# --- build --------------------------------------------------------------------------

if [ -n "$FROM_APP" ]; then
    [ -d "$FROM_APP" ] || die "no app at $FROM_APP"
    # Describe the app that was handed in, not HEAD: it may have been built from
    # anything.
    plist="$FROM_APP/Contents/Info.plist"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist" 2>/dev/null || echo "$VERSION")"
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist" 2>/dev/null || echo "?")"
    COMMIT="$(/usr/libexec/PlistBuddy -c 'Print SPTGitCommit' "$plist" 2>/dev/null || echo "unknown")"
    case "$COMMIT" in ''|*'$('*) COMMIT="unstamped" ;; esac
    step "Using the app at $FROM_APP"
    ditto "$FROM_APP" "$WORK/$APP_NAME.app"
else
    step "Building $APP_NAME $VERSION (build $BUILD_NUMBER, $COMMIT)"
    LOG="$OUT/build.log"
    # Signed ad-hoc by Xcode, which is enough to embed the entitlements and the
    # runtime flag; the Developer ID signature replaces it below. The team stays out
    # of the build so the tracked project never needs one.
    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -derivedDataPath "$WORK/DerivedData" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        SPT_GIT_COMMIT="$COMMIT" \
        SPT_BUILD_DATE="$BUILD_DATE" \
        build > "$LOG" 2>&1; then
        grep -E "error:" "$LOG" | sort -u | head -20 >&2 || true
        die "the build failed; full log: $LOG"
    fi
    ditto "$WORK/DerivedData/Build/Products/Release/$APP_NAME.app" "$WORK/$APP_NAME.app"
fi

APP="$WORK/$APP_NAME.app"

# --- sign ---------------------------------------------------------------------------

SIGN_AS="${IDENTITY:--}"
step "Signing with ${IDENTITY:-an ad-hoc signature (not for distribution)}"

TIMESTAMP=(--timestamp)
[ "$DISTRIBUTABLE" -eq 1 ] || TIMESTAMP=(--timestamp=none)

# Inside out: anything nested is signed before the bundle that contains it, or the
# outer signature seals a nested one that is about to change.
# Sparkle brings helpers of its own inside its framework — Updater.app, the Autoupdate
# binary and, depending on the build, XPC services. A framework's signature only *seals*
# those; each one is code in its own right and notarization refuses the submission unless
# every one of them carries our signature and the hardened runtime.
# The SpeechTextLLM service is signed the same way, after the llama.framework it carries.
NESTED_DIRS=()
for dir in "$APP/Contents/Frameworks" "$APP/Contents/XPCServices"; do
    [ -d "$dir" ] && NESTED_DIRS+=("$dir")
done
if [ "${#NESTED_DIRS[@]}" -gt 0 ]; then
    find "${NESTED_DIRS[@]}" -depth \
        \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.app' \
           -o -name '*.xpc' -o -name 'Autoupdate' \) -print0 |
        while IFS= read -r -d '' nested; do
            codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_AS" "$nested"
        done
fi
# The entitlements are passed explicitly rather than preserved: a Debug-style
# get-task-allow carried over from the build would make notarization refuse the app.
#
# A distributable app also carries the provisioning profile and the keychain group it
# authorises, or its API keys would sit in a plist any process of the user's can read
# (APIKeyStore.swift). Refused rather than skipped, like a missing update key: an image
# without it looks fine and quietly stores every user's keys in the clear.
SIGN_ENTITLEMENTS="$ENTITLEMENTS"
if [ "$DISTRIBUTABLE" -eq 1 ]; then
    source "$REPO_ROOT/scripts/keychain-profile.sh"
    PROFILE="${SPT_PROVISIONING_PROFILE:-$DEFAULT_PROVISIONING_PROFILE}"
    prepare_keychain_signing "$APP" "$IDENTITY" "$PROFILE" "$ENTITLEMENTS" "$WORK/entitlements.plist" ||
        die "cannot sign for the keychain: $KEYCHAIN_SKIP_REASON (docs/releasing.md, Provisioning profile)"
    SIGN_ENTITLEMENTS="$WORK/entitlements.plist"
fi
codesign --force --options runtime "${TIMESTAMP[@]}" \
    --entitlements "$SIGN_ENTITLEMENTS" --sign "$SIGN_AS" "$APP"
codesign --verify --deep --strict "$APP" || die "the signature does not verify"

# codesign's output is captured before grep sees it: piped straight into `grep -q`,
# which exits at the first match, codesign dies of SIGPIPE and pipefail turns a found
# flag into a failure — and a found get-task-allow into a pass.
if grep -q 'get-task-allow' <<< "$(codesign -d --entitlements - "$APP" 2>/dev/null)"; then
    die "the signed app carries get-task-allow, which notarization rejects"
fi
grep -q 'flags=.*runtime' <<< "$(codesign -dv "$APP" 2>&1)" ||
    die "the signed app is missing the hardened runtime flag"
if [ "$DISTRIBUTABLE" -eq 1 ] && ! has_keychain_entitlement "$APP"; then
    die "the signed app names no keychain access group"
fi

# The same question, asked of everything nested: a helper signed without the flag is
# found by the notary service and not by `codesign --verify`.
[ "${#NESTED_DIRS[@]}" -eq 0 ] ||
while IFS= read -r -d '' nested; do
    grep -q 'flags=.*runtime' <<< "$(codesign -dv "$nested" 2>&1)" ||
        die "${nested#"$APP/"} is missing the hardened runtime flag"
done < <(find "${NESTED_DIRS[@]}" -depth \
    \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.app' \
       -o -name '*.xpc' -o -name 'Autoupdate' \) -print0 2>/dev/null)

# An image whose app has no update key is an app that can never be updated, and nothing
# about it looks wrong until the next release fails to reach anyone. The key is public —
# it belongs in Info.plist; docs/releasing.md says where it comes from.
if [ "$DISTRIBUTABLE" -eq 1 ]; then
    /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" > /dev/null 2>&1 ||
        die "Info.plist has no SUPublicEDKey, so this build could not be updated (see docs/releasing.md)"
fi

# --- notarize -----------------------------------------------------------------------

notarize() {  # notarize <file to submit> <what to staple>
    local submission="$1" target="$2" result id
    result="$(xcrun notarytool submit "$submission" "${NOTARY_ARGS[@]}" --wait --output-format json)" || true
    id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
    if ! printf '%s' "$result" | grep -q '"status" *: *"Accepted"'; then
        echo "$result" >&2
        if [ -n "$id" ]; then
            echo "The notary log says:" >&2
            xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
        fi
        die "notarization of $(basename "$target") was not accepted"
    fi
    echo "Accepted ($id)."
    xcrun stapler staple "$target" > /dev/null || die "could not staple the ticket to $(basename "$target")"
}

if [ "$DISTRIBUTABLE" -eq 1 ]; then
    # The app gets its own ticket so it launches cleanly even when it is first opened
    # offline, long after it was copied out of the disk image.
    step "Notarizing the app (this usually takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
    notarize "$WORK/$APP_NAME.zip" "$APP"
fi

# --- disk image ---------------------------------------------------------------------

SUFFIX=""
[ "$DISTRIBUTABLE" -eq 1 ] || SUFFIX="-unsigned"
DMG="$OUT/$APP_NAME-$VERSION$SUFFIX.dmg"

step "Making $(basename "$DMG")"
# The window a user sees on opening the image: a title, the app, an arrow, Applications
# and a line on what comes next, on a white card in the setup window's green glass rim. Its layout lives in the image's .DS_Store, which
# dmgbuild writes directly — scripting Finder instead needs an Automation grant and
# someone at the screen, and a tag builds on a runner with neither.
DMG_DIR="$REPO_ROOT/scripts/dmg"
new_enough() { "$1" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; }
if [ -n "${SPT_PYTHON:-}" ]; then
    PYTHON="$SPT_PYTHON"
    new_enough "$PYTHON" ||
        die "dmgbuild needs Python 3.10 or later; SPT_PYTHON is $("$PYTHON" --version 2>&1)"
else
    PYTHON=""
    for candidate in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
        if new_enough "$candidate"; then PYTHON="$candidate"; break; fi
    done
    [ -n "$PYTHON" ] ||
        die "dmgbuild needs Python 3.10 or later, and none is on PATH; set SPT_PYTHON to one"
fi
"$PYTHON" -m venv "$WORK/venv" || die "could not create a Python virtual environment"
"$WORK/venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --no-deps --only-binary=:all: -r "$DMG_DIR/requirements.txt" ||
    die "could not install dmgbuild (scripts/dmg/requirements.txt)"

mkdir -p "$WORK/dmg"
swift "$DMG_DIR/background.swift" "$WORK/dmg" || die "could not draw the disk image background"

rm -f "$DMG"
# The image's own icon is the app's, so it is recognisable on the desktop and in Finder's
# sidebar.
"$WORK/venv/bin/dmgbuild" -s "$DMG_DIR/dmgbuild-settings.py" \
    -D app="$APP" \
    -D background="$WORK/dmg/background.png" \
    -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "$APP_NAME $VERSION" "$DMG" > "$WORK/dmgbuild.log" 2>&1 ||
    { cat "$WORK/dmgbuild.log" >&2; die "dmgbuild could not create the disk image"; }

# The app inside the image is the copy people install, so that copy is the one checked:
# dmgbuild writes Finder attributes onto what it copies, and an extended attribute on the
# bundle fails a strict check the app it was copied from passed.
MOUNT="$(mktemp -d "$WORK/mount.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" > /dev/null ||
    die "could not mount the disk image to check it"
if ! codesign --verify --deep --strict "$MOUNT/$APP_NAME.app"; then
    hdiutil detach -quiet "$MOUNT"
    die "the app inside the disk image does not pass a strict signature check"
fi
hdiutil detach -quiet "$MOUNT"

if [ "$DISTRIBUTABLE" -eq 1 ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    step "Notarizing the disk image"
    notarize "$DMG" "$DMG"

    step "Asking Gatekeeper"
    spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
    spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /'
fi

shasum -a 256 "$DMG" | sed "s|  .*/|  |" > "$DMG.sha256"

# --- summary ------------------------------------------------------------------------

echo ""
echo "SUMMARY"
echo "  image:    $DMG"
echo "  sha256:   $(cut -d' ' -f1 "$DMG.sha256")"
echo "  version:  $VERSION (build $BUILD_NUMBER, $COMMIT)"
if [ "$DISTRIBUTABLE" -eq 1 ]; then
    echo "  signed:   $IDENTITY"
    echo "  notarized and stapled: app and disk image"
else
    echo "  signed:   ad-hoc — NOT for distribution"
    echo "  Gatekeeper will block this image on any other Mac. Set SPT_DEVELOPER_ID and"
    echo "  notary credentials to build one people can install (docs/releasing.md)."
fi
