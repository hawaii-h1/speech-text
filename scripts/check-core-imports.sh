#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fails when a file in SpeechTextCore imports a module the package must not reach.
#
#   scripts/check-core-imports.sh [DIR]
#       Scans every .swift file under DIR (default: Packages/SpeechTextCore/Sources).
#
# SwiftUI is the one that matters: the package is the app's logic, which the tests
# reach without the app, and a view or anything that needs one belongs in
# SpeechText/SpeechText/. The manifest cannot refuse it — SwiftUI is a system
# framework, not a dependency. WhisperKit, FluidAudio, Sparkle and llama are already a
# build error there, since the manifest declares no dependency; they are listed so
# that a dependency added to Package.swift one day is still caught here.
#
# Every import form counts: `@preconcurrency import`, `@_exported import`,
# `@testable import`, `import struct SwiftUI.Color`. A comment that mentions an import
# does not, since only a line that begins with one is read. Plain grep -E, so it runs
# alike on macOS and Linux.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${1:-$root/Packages/SpeechTextCore/Sources}"
[ -d "$dir" ] || { echo "no directory at $dir" >&2; exit 2; }

modules='SwiftUI|WhisperKit|FluidAudio|Sparkle|llama'
pattern="^[[:space:]]*(@[[:alnum:]_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?($modules)([^[:alnum:]_]|\$)"

found=$(find "$dir" -name '*.swift' -print0 | xargs -0 grep -nE "$pattern" /dev/null || true)

if [ -n "$found" ]; then
    echo "SpeechTextCore imports a module it must not reach:"
    printf '%s\n' "$found" | sed "s|^$root/|  |"
    echo
    echo "A view, or anything that needs SwiftUI or an engine, belongs in SpeechText/SpeechText/;"
    echo "the package holds logic the tests reach without the app (docs/development.md › Tests)."
    exit 1
fi

count=$(find "$dir" -name '*.swift' | wc -l | tr -d ' ')
echo "No file under ${dir#$root/} imports SwiftUI, WhisperKit, FluidAudio, Sparkle or llama ($count files)."
