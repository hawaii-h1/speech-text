#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Lints the Swift files a branch adds or changes with Xcode's swift-format, and
# reports only the findings that name a semantic rule, on a line the branch added
# or changed.
#
#   scripts/lint-swift.sh [BASE]
#       BASE is a ref (default origin/main). The files are the added or modified
#       .swift files in `BASE...HEAD`; with none, the script exits 0. Exit 1 when
#       a line the branch added or changed has a finding from the rules below. A
#       finding elsewhere in the same file is old, belongs to nobody's pull request
#       and is not reported: CONTRIBUTING.md refuses restyling, so a bug fix must
#       not be made to carry it. A parse error (`error:`) is always reported.
#
# Why only some rules, and only changed lines: the code is wrapped the way Xcode
# wraps it, aligned under the first argument, which swift-format's pretty-printer
# cannot express — running it over the tree rewrites about 9,500 lines. Its
# pretty-printer findings (Indentation, AddLines, Spacing, LineLength,
# TrailingComma, RemoveLine) cannot be switched off in .swift-format, so they are
# dropped here by rule tag. Nothing is ever reformatted. The rules kept are the
# ones that name a construct to avoid rather than a layout to follow, and they
# are the `true` entries of .swift-format — keep the two lists the same.
set -euo pipefail

base=${1:-origin/main}
cd "$(git rev-parse --show-toplevel)"

enforced='NoBlockComments|UseTripleSlashForDocumentationComments|OnlyOneTrailingClosureArgument|ReplaceForEachWithForLoop|OneCasePerLine|UseLetInEveryBoundCaseVariable|NoParensAroundConditions|NoCasesWithOnlyFallthrough|NoEmptyTrailingClosureParentheses|ReturnVoidInsteadOfEmptyTuple|UseShorthandTypeNames|UseSingleLinePropertyGetter|AmbiguousTrailingClosureOverload|AvoidRetroactiveConformances|FullyIndirectEnum|NoAssignmentInExpressions|TypeNamesShouldBeCapitalized|IdentifiersMustBeASCII'

# The changed line ranges, one "path first last" per hunk of the new side. A new
# file is one hunk covering every line; a hunk that only deletes (length 0) adds
# nothing to report. Quoting is off so a path is the plain path.
ranges=$(
    git -c core.quotePath=false diff -U0 --no-color --diff-filter=AM "$base...HEAD" -- '*.swift' |
        awk '
            /^\+\+\+ b\// { file = substr($0, 7); next }
            /^@@ / {
                spec = $3                      # +start or +start,count
                sub(/^\+/, "", spec)
                n = split(spec, part, ",")
                count = (n > 1) ? part[2] : 1
                if (count > 0) print file, part[1], part[1] + count - 1
            }
        '
)

files=()
while IFS= read -r file; do
    files+=("$file")
done < <(printf '%s\n' "$ranges" | awk 'NF { print $1 }' | sort -u)

if [ ${#files[@]} -eq 0 ]; then
    echo "No Swift lines changed since $base."
    exit 0
fi

findings=$(
    for file in "${files[@]}"; do
        xcrun swift-format lint --configuration .swift-format "$file" 2>&1 || true
    done | RANGES="$ranges" awk -v enforced="$enforced" '
        BEGIN {
            enforced = "[[](" enforced ")[]]"
            n = split(ENVIRON["RANGES"], rows, "\n")
            for (i = 1; i <= n; i++) {
                split(rows[i], r, " ")
                count[r[1]]++
                first[r[1], count[r[1]]] = r[2]
                last[r[1], count[r[1]]] = r[3]
            }
        }
        / error: / { print; next }
        $0 ~ enforced && match($0, /^[^:]+:[0-9]+:/) {
            head = substr($0, 1, RLENGTH - 1)
            split(head, at, ":")
            for (i = 1; i <= count[at[1]]; i++)
                if (at[2] >= first[at[1], i] && at[2] <= last[at[1], i]) { print; break }
        }
    '
)

if [ -n "$findings" ]; then
    printf '%s\n' "$findings"
    echo
    echo "These are the findings on the lines this branch changes, in ${#files[@]} Swift file(s)."
    echo "Fix them in the lines you touched; findings elsewhere in a file are old and are not"
    echo "reported, and the formatter itself is never run over the code (CONTRIBUTING.md › Formatting)."
    exit 1
fi
echo "No swift-format findings on the changed lines of ${#files[@]} Swift file(s)."
