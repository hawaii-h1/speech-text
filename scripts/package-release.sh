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

WORK="$(mktemp -d -t speechtext-release)"
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
if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) -print0 |
        while IFS= read -r -d '' nested; do
            codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_AS" "$nested"
        done
fi
# The entitlements are passed explicitly rather than preserved: a Debug-style
# get-task-allow carried over from the build would make notarization refuse the app.
codesign --force --options runtime "${TIMESTAMP[@]}" \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_AS" "$APP"
codesign --verify --deep --strict "$APP" || die "the signature does not verify"

if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'get-task-allow'; then
    die "the signed app carries get-task-allow, which notarization rejects"
fi
codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime' || die "the signed app is missing the hardened runtime flag"

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
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
# The drag-to-install target. A symlink, so the image holds no second copy of anything.
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG" || die "hdiutil could not create the disk image"

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
