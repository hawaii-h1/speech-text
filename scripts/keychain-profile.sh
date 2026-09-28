# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sourced by rebuild.sh and package-release.sh: embeds the Developer ID provisioning
# profile that lets SpeechText keep its API keys in the data-protection keychain, and
# writes the entitlements that name its keychain access group.
#
# Those entitlements are *restricted*: a signature that claims them without an embedded
# profile authorising them — for this team, this app and this very certificate — is
# refused by the system and the app never launches. So nothing is embedded unless all
# three match, and the tracked SpeechText.entitlements never carries them: a build
# without the profile (Xcode ⌘R, a contributor's clone) keeps its keys in UserDefaults
# instead (see APIKeyStore.swift).

# The keychain group the API keys live in, after the team prefix. Fixed, *not* derived
# from the bundle identifier: the app has been renamed three times, and a group that
# followed the next rename would leave every stored key in a group the app no longer
# names — invisible, with the plain-text copies already deleted. The profile authorises
# TEAMID.*, so any future identifier can still claim this group.
KEYCHAIN_GROUP_SUFFIX="app.speech-text.SpeechText"

# Where the maintainer keeps the profile; SPT_PROVISIONING_PROFILE overrides it.
DEFAULT_PROVISIONING_PROFILE="$HOME/.config/speech-text/SpeechText_Developer_ID.provisionprofile"

# prepare_keychain_signing APP IDENTITY PROFILE BASE_ENTITLEMENTS OUT_ENTITLEMENTS
#
# On success the profile is at APP/Contents/embedded.provisionprofile and OUT_ENTITLEMENTS
# is BASE_ENTITLEMENTS plus the keychain group; sign APP with it. On failure nothing is
# changed and KEYCHAIN_SKIP_REASON says why.
prepare_keychain_signing() {
    local app="$1" identity="$2" profile="$3" base="$4" out="$5"
    KEYCHAIN_SKIP_REASON=""

    if [ ! -f "$profile" ]; then
        KEYCHAIN_SKIP_REASON="no provisioning profile at $profile"; return 1
    fi
    local team
    team="$(printf '%s' "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
    if [ -z "$team" ]; then
        KEYCHAIN_SKIP_REASON="\"$identity\" is not a certificate with a team"; return 1
    fi

    local decoded
    decoded="$(mktemp -t speech-text-profile)"
    if ! security cms -D -i "$profile" > "$decoded" 2>/dev/null; then
        rm -f "$decoded"
        KEYCHAIN_SKIP_REASON="$profile is not a readable provisioning profile"; return 1
    fi

    local profile_team app_id expiry bundle now
    profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded" 2>/dev/null)"
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null)"
    expiry="$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null)"
    bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "$profile_team" != "$team" ]; then
        KEYCHAIN_SKIP_REASON="the profile is for team $profile_team, the certificate for $team"
    elif [ "$app_id" != "$team.$bundle" ]; then
        KEYCHAIN_SKIP_REASON="the profile is for $app_id, the app is $team.$bundle"
    elif [ -z "$expiry" ] || [[ "$expiry" < "$now" ]]; then
        KEYCHAIN_SKIP_REASON="the profile expired on ${expiry:-an unreadable date}"
    else
        # The profile lists the certificates it authorises; signing with any other — an
        # Apple Development one of the same team, say — would not launch.
        local cert_hash index=0 listed=0 der
        cert_hash="$(security find-identity -p codesigning 2>/dev/null |
            grep -F "\"$identity\"" | head -1 | awk '{print $2}')"
        while der="$(plutil -extract "DeveloperCertificates.$index" raw -o - "$decoded" 2>/dev/null)"; do
            if [ "$(printf '%s' "$der" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')" = "$cert_hash" ]; then
                listed=1; break
            fi
            index=$((index + 1))
        done
        [ "$listed" -eq 1 ] || KEYCHAIN_SKIP_REASON="the profile does not list the certificate \"$identity\""
    fi
    rm -f "$decoded"
    [ -z "$KEYCHAIN_SKIP_REASON" ] || return 1

    cp "$profile" "$app/Contents/embedded.provisionprofile"
    cp "$base" "$out"
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $team.$bundle" \
        -c "Add :com.apple.developer.team-identifier string $team" \
        -c "Add :keychain-access-groups array" \
        -c "Add :keychain-access-groups:0 string $team.$KEYCHAIN_GROUP_SUFFIX" \
        "$out"
}

# has_keychain_entitlement APP — whether APP's signature names a keychain access group.
has_keychain_entitlement() {
    grep -q 'keychain-access-groups' <<< "$(codesign -d --entitlements - "$1" 2>/dev/null)"
}
