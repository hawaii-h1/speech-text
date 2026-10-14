#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Reads the ```touchpoints table in docs/adding-a-provider.md.
#
#   scripts/check-provider-guide.sh
#       Every file and anchor the table names still exists, and every capability value
#       (a case of STTModelDescriptor's enums or of Dialect) is in the guide's vocabulary
#       table. CI runs this, so a rename, or a new capability nobody documented, fails
#       the pull request instead of misleading the next contributor.
#
#   scripts/check-provider-guide.sh KINDS NAME [NAME...]
#       The touchpoints of those kinds (comma-separated: stt,realtime,llm,key,docs) and
#       whether each already mentions the vendor. NAME is matched case-insensitively,
#       and any of several spellings counts (elevenlabs "eleven labs").
#       Example: scripts/check-provider-guide.sh stt,key,docs deepgram
#       Exits 1 while a manual touchpoint is still missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
guide=docs/adding-a-provider.md

rows() {
    awk '/^```touchpoints/ { inside = 1; next } /^```/ { inside = 0 } inside' "$guide" \
        | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# The block that starts at the first line containing ANCHOR. In Swift: from the first
# `{` (or, on a line with none, from `= [`) until the brackets balance — rough, since
# brackets in strings and comments count too, but enough to tell one declaration from
# the next. In Markdown: a heading's section, up to the next heading of its level or
# above; any other anchor is its own line.
block() {
    case $1 in
        *.md)
            awk -v anchor="$2" '
                !started && index($0, anchor) {
                    started = 1; print
                    if (match($0, /^#+ /)) level = RLENGTH - 1; else exit
                    next
                }
                started {
                    if (match($0, /^#+ /) && RLENGTH - 1 <= level) exit
                    print
                }
            ' "$1"
            return
            ;;
    esac
    awk -v anchor="$2" '
        !started && index($0, anchor) { started = 1 }
        !started { next }
        {
            line = $0
            if (!mode) {
                if (index(line, "{")) { mode = "{"; line = substr(line, index(line, "{")) }
                else if (index(line, "= [")) { mode = "["; line = substr(line, index(line, "= [") + 2) }
            }
            print
            if (!mode) { if (++waited > 5) exit; next }
            opener = (mode == "{") ? "{" : "["
            closer = (mode == "{") ? "}" : "]"
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == opener) depth++
                else if (c == closer && --depth == 0) exit
            }
            if (++count > 600) exit
        }
    ' "$1"
}

check_anchors() {
    local failed=0 n=0
    while IFS='|' read -r kind file anchor check todo; do
        file=$(printf '%s' "$file" | trim)
        anchor=$(printf '%s' "$anchor" | trim)
        n=$((n + 1))
        if [ ! -f "$file" ]; then
            echo "✗ $file does not exist (anchor: $anchor)"
            failed=1
        elif ! grep -Fq -- "$anchor" "$file"; then
            echo "✗ $file no longer contains: $anchor"
            failed=1
        fi
    done < <(rows)
    # Every capability value the code has is explained in the guide's vocabulary table.
    local vocab
    for spec in \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum Delivery" \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum TranscriptForm" \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum LanguageSupport" \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum BatchUpload" \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum Requirement" \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum Vocabulary" \
        "SpeechText/SpeechText/STTModelCatalog.swift|enum ListPrice" \
        "SpeechText/SpeechText/ChatClients.swift|enum Dialect" \
        "SpeechText/SpeechText/ChatClients.swift|enum ReasoningOutput" \
        "SpeechText/SpeechText/Transcribers.swift|enum VocabularyField"; do
        file=${spec%%|*}
        anchor=${spec#*|}
        vocab=$(block "$file" "$anchor" | sed -n 's/^[[:space:]]*case \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p')
        if [ -z "$vocab" ]; then
            echo "✗ $file › $anchor: no cases found (renamed or moved?)"
            failed=1
        fi
        for name in $vocab; do
            n=$((n + 1))
            if ! grep -Fq -- "\`.$name" "$guide"; then
                echo "✗ $anchor has .$name, which the guide's capability vocabulary does not explain"
                failed=1
            fi
        done
    done

    if [ "$failed" -ne 0 ]; then
        echo
        echo "$guide names code that is gone, or misses a capability the code gained."
        echo "Update its Touchpoints or capability vocabulary table, and the section that"
        echo "describes the change, in this pull request."
        exit 1
    fi
    echo "✓ all $n touchpoints and capability values in $guide match the code"
}

check_vendor() {
    local kinds=",$1," missing=0
    shift
    mentions() {
        local text=$1 name
        for name in "${names[@]}"; do
            grep -Fqi -- "$name" <<< "$text" && return 0
        done
        return 1
    }
    names=("$@")
    while IFS='|' read -r kind file anchor check todo; do
        kind=$(printf '%s' "$kind" | trim)
        file=$(printf '%s' "$file" | trim)
        anchor=$(printf '%s' "$anchor" | trim)
        check=$(printf '%s' "$check" | trim)
        todo=$(printf '%s' "$todo" | trim)
        case $kinds in *",$kind,"*) ;; *) continue ;; esac
        where="$file › $anchor"
        case $check in
            compiler) echo "  build   $where — $todo" ;;
            review)   echo "  review  $where — $todo" ;;
            manual|manual:file)
                if [ "$check" = manual ]; then text=$(block "$file" "$anchor"); else text=$(cat "$file"); fi
                if mentions "$text"; then
                    echo "✓ done    $where"
                else
                    echo "✗ todo    $where — $todo"
                    missing=1
                fi
                ;;
            *) echo "? $where has an unknown check '$check'"; missing=1 ;;
        esac
    done < <(rows)
    echo
    echo "build: the compiler lists these once the enum case exists. review: answer by hand."
    return "$missing"
}

if [ $# -eq 0 ]; then
    check_anchors
elif [ $# -ge 2 ]; then
    check_vendor "$@"
else
    sed -n '5,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi
