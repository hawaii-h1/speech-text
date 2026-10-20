#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Makes the audio clips docs/adding-a-provider.md › "Measure before you write" sends to
# a speech vendor, in the formats the app itself sends: 16 kHz mono, FLAC and WAV.
#
#   scripts/provider-test-clips.sh            into /tmp/speech-text-clips
#   scripts/provider-test-clips.sh DIR        into DIR
#
# The speech clips are text-to-speech, so they check formats and the protocol, never
# quality: every engine transcribes `say` nearly perfectly. Judge quality on a real
# recording (History keeps failed ones under Recordings/).
#
# Uses only what macOS ships: say, afconvert.
set -euo pipefail

out=${1:-/tmp/speech-text-clips}
mkdir -p "$out"
cd "$out"

# A WAV of digital silence, 16-bit mono: the header written by hand, the samples zeros.
silence() { # file seconds rate
    local file=$1 rate=$3
    local bytes
    bytes=$(awk -v s="$2" -v r="$rate" 'BEGIN { printf "%d", s * r * 2 }')
    le32() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)); }
    {
        printf 'RIFF'; printf "$(le32 $((36 + bytes)))"; printf 'WAVE'
        printf 'fmt '; printf "$(le32 16)"; printf '\x01\x00\x01\x00'
        printf "$(le32 "$rate")"; printf "$(le32 $((rate * 2)))"; printf '\x02\x00\x10\x00'
        printf 'data'; printf "$(le32 "$bytes")"
        head -c "$bytes" /dev/zero
    } > "$file"
}

to16k() { # in.aiff name
    afconvert -f WAVE -d LEI16@16000 -c 1 "$1" "$2.wav"
    afconvert -f flac -d flac@16000 -c 1 "$1" "$2.flac"
}

say -o speech-en.aiff "This is a short dictation, recorded to check that the upload format is accepted."
to16k speech-en.aiff speech-en
# 24 kHz for a realtime socket that takes nothing else (OpenAI's).
afconvert -f WAVE -d LEI16@24000 -c 1 speech-en.aiff speech-en-24k.wav

if say -v '?' | grep -q '^Lesya '; then
    say -v Lesya -o speech-uk.aiff "Це коротке диктування, щоб перевірити формат і мову."
    to16k speech-uk.aiff speech-uk
fi
rm -f ./*.aiff

silence silence-2s.wav 2 16000
afconvert -f flac -d flac@16000 silence-2s.wav silence-2s.flac
# Under one FLAC block (4,608 frames), so the app would send it as WAV.
silence short-0.2s.wav 0.2 16000
silence short-0.3s.wav 0.3 16000

echo "Clips in $out:"
for f in *; do printf '  %-22s %s\n' "$f" "$(afinfo "$f" 2>/dev/null | awk -F': *' '/estimated duration/ { print $2 }')"; done
echo
echo "A realtime socket is easier to exercise from the app itself, with the Debug Log open."
