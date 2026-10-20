#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fails when a Debug Log line could carry what the user dictated, selected or had
# rewritten.
#
#   scripts/check-log-privacy.sh [DIR]
#       Scans every .swift file under DIR (default: SpeechText/ and Packages/SpeechTextCore/,
#       where the app's logic lives) for `dlog(…)` calls
#       and for the bare `log(…)` wrappers that forward to it (TranscriptSpan.swift's).
#       Every Debug Log entry also goes to the system log as public (DebugLog.swift), so
#       an entry may say how long a text is, never what it says.
#
# What fails, inside an interpolation `\(…)` of such a call — multi-line calls joined:
#   - `.prefix(` or `.suffix(` (a UUID's `uuidString.prefix(8)` excepted);
#   - a value whose name says it is text — `text`, `transcript`, `partial`, `committed`,
#     `delta`, `instruction`, `selection`, `record`, `reply`, `windowTitle`, the
#     vocabulary's `terms` / `keyterms` / `keywords` / `vocabulary`, or any name ending
#     in `Text` / `Transcript` (`finalText`, `liveText`, `selection.text`, …) — unless it
#     is only measured: `.count`, `.utf8.count`, `.utf16.count`, `.isEmpty`, `== nil`,
#     `!= nil`, or `(x as NSString).length`.
#
# What it cannot see: a value passed through `String(format:)`'s `%@`, a message built
# into a variable before the call, or a text-carrying value under an innocent name.
# Review those by hand.
#
# A reviewed exception — a vendor's error words, say — carries a comment on the line of
# the call or the line above it:
#       // log-privacy: ok — <why this is not the user's text>
set -euo pipefail

cd "$(dirname "$0")/.."
dir=${1:-SpeechText Packages/SpeechTextCore}

# shellcheck disable=SC2086
files=$(find $dir -name '*.swift' -type f | sort)
[ -n "$files" ] || { echo "No Swift files under $dir" >&2; exit 2; }

# shellcheck disable=SC2086
awk '
function flush_call(   n, i, item, why) {
    n = split(interps, items, "\034")
    for (i = 1; i <= n; i++) {
        item = items[i]
        if (item == "") continue
        why = judge(item)
        if (why != "") {
            printf "%s:%d: %s in \\(%s)\n", FILENAME, call_line, why, item
            failures++
        }
    }
}

# Returns why an interpolation may carry user text, or "" when it cannot.
function judge(s,   rest, name, last, chain) {
    # String literals inside the interpolation (a ternary'"'"'s branches) are words of ours.
    gsub(/"[^"\\]*"/, "\"\"", s)
    if (s ~ /\.(prefix|suffix)\(/) {
        rest = s
        gsub(/uuidString\.prefix\(/, "", rest)
        if (rest ~ /\.(prefix|suffix)\(/) return "a slice of a value"
    }
    gsub(/\[[^]]*\]/, "", s)
    gsub(/\([A-Za-z_][A-Za-z0-9_.]* as NSString\)\.length/, "0", s)
    gsub(/[A-Za-z_][A-Za-z0-9_.]*\([^()]*\)\.(utf8\.count|utf16\.count|count|isEmpty)/, "0", s)
    gsub(/[A-Za-z_][A-Za-z0-9_]*([?!]?\.[A-Za-z_][A-Za-z0-9_]*)*[?!]?\.(utf8\.count|utf16\.count|count|isEmpty)/, "0", s)
    gsub(/[A-Za-z_][A-Za-z0-9_]*([?!]?\.[A-Za-z_][A-Za-z0-9_]*)*[?!]? *[!=]= *nil/, "0", s)
    # What is left: every identifier chain, judged by its last name.
    while (match(s, /[A-Za-z_][A-Za-z0-9_]*([?!]?\.[A-Za-z_][A-Za-z0-9_]*)*/)) {
        chain = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        last = chain
        sub(/.*\./, "", last)
        if (last ~ /^(text|transcript|partial|committed|delta|instruction|selection|record|reply|windowTitle|terms|keyterms|keywords|vocabulary)$/ \
            || (last ~ /[a-z](Text|Transcript)$/ && last !~ /^(is|has|shows|wants|should)[A-Z]/))
            return "text-shaped value `" chain "`"
    }
    return ""
}

FNR == 1 { in_call = 0; prev = "" }

{
    line = $0
    start = 1
    if (!in_call) {
        if (match(line, /(^|[^A-Za-z0-9_.])(dlog|log)\(/) == 0) { prev = line; next }
        if (line ~ /^[[:space:]]*\/\//) { prev = line; next }
        if (line ~ /func (dlog|log)\(/) { prev = line; next }
        allowed = (line ~ /log-privacy: ok/ || prev ~ /log-privacy: ok/)
        in_call = 1; call_line = FNR
        start = RSTART + RLENGTH       # just past the call'"'"'s opening paren
        depth = 1; nmodes = 0; interps = ""; capture = 0; cdepth = 0; cur = ""
    } else if (line ~ /log-privacy: ok/) {
        allowed = 1
    }
    # Character scan: modes stack "s" (string) and "i" (interpolation, code inside).
    for (i = start; i <= length(line) && in_call; i++) {
        c = substr(line, i, 1)
        mode = nmodes ? modes[nmodes] : "c"
        if (mode == "s") {
            if (c == "\\") {
                if (substr(line, i + 1, 1) == "(") {
                    i++
                    modes[++nmodes] = "i"; pdepth[nmodes] = 1
                    if (!capture) { capture = 1; cdepth = nmodes; cur = ""; continue }
                    cur = cur "\\("
                    continue
                }
                if (capture) cur = cur c substr(line, i + 1, 1)
                i++
                continue
            }
            if (c == "\"") nmodes--
            if (capture) cur = cur c
            continue
        }
        # Code: the call itself, or the inside of an interpolation.
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        if (c == "\"") { modes[++nmodes] = "s"; if (capture) cur = cur c; continue }
        if (c == "(") {
            if (mode == "i") pdepth[nmodes]++; else depth++
            if (capture) cur = cur c
            continue
        }
        if (c == ")") {
            if (mode == "i") {
                if (--pdepth[nmodes] == 0) {
                    if (capture && nmodes == cdepth) {
                        interps = interps "\034" cur; capture = 0
                    } else if (capture) cur = cur c
                    nmodes--
                    continue
                }
                if (capture) cur = cur c
                continue
            }
            if (--depth == 0) {
                if (!allowed) flush_call()
                in_call = 0
            }
            continue
        }
        if (capture) cur = cur c
    }
    if (in_call && capture) cur = cur " "
    prev = line
}

END {
    if (failures) {
        print ""
        print failures " Debug Log interpolation(s) above may carry the user'"'"'s text."
        print "Every entry goes to the system log as public: log a count (`.count`), never the"
        print "words. A reviewed exception takes `// log-privacy: ok — why` on or above the call."
        exit 1
    }
}
' $files

echo "Log privacy: no Debug Log line interpolates the user's text."
