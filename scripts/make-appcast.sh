#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Write the appcast — the feed Sparkle reads inside the app to learn that a newer
# version exists, and to prove the download is ours.
#
#   make-appcast.sh --dmg PATH --tag vX.Y.Z [--notes PATH] [--out DIR]
#
# The signing key is an EdDSA key pair that has nothing to do with Apple's: the public
# half is `SUPublicEDKey` in Info.plist, the private half signs every release. It comes
# from the environment or from the Keychain —
#
#   SPT_SPARKLE_KEY      the private key itself (what `generate_keys -x` writes), or
#   SPT_SPARKLE_KEY_FILE a file holding it; without either, the Keychain is used, which
#                        is what a release built by hand on the maintainer's Mac does.
#
# The feed holds exactly one item: the release being cut. Sparkle only ever installs the
# best item it finds, and a one-item feed means a release needs nothing from the release
# before it — no archive of old disk images to keep, nothing to re-sign. The cost is that
# the "what's new" text in the update window covers this version only; the full history
# stays in CHANGELOG.md.
#
# docs/releasing.md explains where the key comes from and how the feed is published.

set -euo pipefail

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
REPO_URL="https://github.com/yavno/speech-text"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG=""
TAG=""
NOTES=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dmg)   DMG="$2"; shift ;;
        --tag)   TAG="$2"; shift ;;
        --notes) NOTES="$2"; shift ;;
        --out)   OUT="$2"; shift ;;
        -h|--help)
            awk '/^# Write the appcast/,0 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

[ -f "$DMG" ] || die "--dmg needs the disk image this release ships"
[ -n "$TAG" ] || die "--tag needs the release tag, e.g. --tag v1.1.0"
OUT="${OUT:-$(cd "$(dirname "$DMG")" && pwd)}"
mkdir -p "$OUT"

# --- the signing tools ---------------------------------------------------------------
#
# Sparkle's own binaries, pinned and checksummed: generate_appcast reads the version and
# the minimum macOS out of the app inside the image, so neither is retyped here and
# neither can drift from what was actually built.

TOOLS="$REPO_ROOT/build/tools/sparkle-$SPARKLE_VERSION"
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
    step "Fetching Sparkle $SPARKLE_VERSION's tools"
    mkdir -p "$TOOLS"
    archive="$TOOLS/../Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fsSL -o "$archive" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" ||
        die "could not download Sparkle $SPARKLE_VERSION"
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    [ "$actual" = "$SPARKLE_SHA256" ] ||
        die "the Sparkle download has checksum $actual, not the pinned $SPARKLE_SHA256"
    tar -xf "$archive" -C "$TOOLS"
    rm -f "$archive"
fi

# --- the key --------------------------------------------------------------------------

KEY_ARGS=()
KEY_FILE=""
cleanup() { [ -n "$KEY_FILE" ] && rm -f "$KEY_FILE"; }
trap cleanup EXIT

if [ -n "${SPT_SPARKLE_KEY:-}" ]; then
    KEY_FILE="$(mktemp)"
    chmod 600 "$KEY_FILE"
    printf '%s' "$SPT_SPARKLE_KEY" > "$KEY_FILE"
    KEY_ARGS=(--ed-key-file "$KEY_FILE")
elif [ -n "${SPT_SPARKLE_KEY_FILE:-}" ]; then
    [ -f "$SPT_SPARKLE_KEY_FILE" ] || die "SPT_SPARKLE_KEY_FILE points at nothing: $SPT_SPARKLE_KEY_FILE"
    KEY_ARGS=(--ed-key-file "$SPT_SPARKLE_KEY_FILE")
else
    echo "No key in the environment — using the one in the Keychain."
fi

# --- the feed ---------------------------------------------------------------------------
#
# generate_appcast works on a directory of update files. Release notes travel as a file
# beside the image with the same name, which is how it knows they belong together.

STAGE="$(mktemp -d)"
trap 'cleanup; rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/"
if [ -n "$NOTES" ]; then
    [ -f "$NOTES" ] || die "--notes points at nothing: $NOTES"
    cp "$NOTES" "$STAGE/$(basename "${DMG%.dmg}").md"
fi

step "Writing the appcast for $TAG"
"$TOOLS/bin/generate_appcast" \
    "${KEY_ARGS[@]}" \
    --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
    --link "$REPO_URL" \
    --full-release-notes-url "$REPO_URL/blob/main/CHANGELOG.md" \
    --embed-release-notes \
    --maximum-versions 1 \
    "$STAGE" || die "generate_appcast could not write the feed"

[ -f "$STAGE/appcast.xml" ] || die "generate_appcast wrote no appcast.xml"

# The enclosure has to point at the asset the release workflow uploads, and a wrong URL
# here fails only later, on a user's Mac, as an update that cannot be downloaded.
grep -q "$REPO_URL/releases/download/$TAG/$(basename "$DMG")" "$STAGE/appcast.xml" ||
    die "the feed does not point at $TAG/$(basename "$DMG")"
# generate_appcast signs an update only when the app inside the image asks to be
# updated with a signature, so an unsigned feed usually means one thing: the app was
# built without SUPublicEDKey in Info.plist. Sparkle would refuse such an update anyway.
grep -q 'sparkle:edSignature' "$STAGE/appcast.xml" ||
    die "the feed carries no EdDSA signature — check that the app in $(basename "$DMG") has SUPublicEDKey in Info.plist (docs/releasing.md)"

cp "$STAGE/appcast.xml" "$OUT/appcast.xml"
printf '\nWrote %s\n' "$OUT/appcast.xml"
