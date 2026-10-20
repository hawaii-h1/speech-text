#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Replays every recorded dictation trace through the app's own recognition and delivery
# code (RecordedTraceTests). The traces hold dictated words, so they live outside this
# repository, in the folder SPEECHTEXT_TRACES names. Without it the test is
# skipped, which is what CI does.
#
#   SPEECHTEXT_TRACES=<traces-dir> scripts/replay-traces.sh
#
# SPT_DERIVED_DATA picks the build folder (default /tmp/st-dd-traces).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${SPEECHTEXT_TRACES:-}" ] ||
  { echo "SPEECHTEXT_TRACES must name the folder the traces are kept in" >&2; exit 64; }
TRACES="$SPEECHTEXT_TRACES"
[ -d "$TRACES" ] || { echo "no traces folder at $TRACES — set SPEECHTEXT_TRACES" >&2; exit 1; }
TRACES="$(cd "$TRACES" && pwd)"
echo "Replaying $(ls "$TRACES"/*.json 2>/dev/null | wc -l | tr -d ' ') trace(s) from $TRACES"

# An unhosted test bundle does not inherit this environment; xcodebuild passes
# TEST_RUNNER_<NAME> through as <NAME>.
LOG="$(mktemp -t replay-traces)"
status=0
TEST_RUNNER_SPEECHTEXT_TRACES="$TRACES" xcodebuild test \
  -project "$REPO_ROOT/SpeechText/SpeechText.xcodeproj" -scheme SpeechText -destination 'platform=macOS' \
  -derivedDataPath "${SPT_DERIVED_DATA:-/tmp/st-dd-traces}" \
  -only-testing:SpeechTextTests/RecordedTraceTests > "$LOG" 2>&1 || status=$?
grep -E "error:|' failed|' skipped|TEST (SUCCEEDED|FAILED)" "$LOG" || tail -20 "$LOG"
echo "Full log: $LOG"
exit "$status"
