#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copies a dictation trace recorded by the app (Debug Log › Record traces, or
# scripts/e2e.sh --traces) into the private traces folder, where RecordedTraceTests
# replays it when scripts/replay-traces.sh runs.
#
#   scripts/import-trace.sh                 the newest trace, named after its date
#   scripts/import-trace.sh t5-terminal     the newest trace, as t5-terminal.json
#   scripts/import-trace.sh NAME FILE.json  a specific trace (an e2e run's, for one)
#
# A trace holds the words that were dictated, in plain text, so it never goes into this
# repository: SPEECHTEXT_TRACES names the folder, which must be outside it.
#
#   SPEECHTEXT_TRACES=<traces-dir> scripts/import-trace.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$HOME/Library/Application Support/SpeechText/Traces"
[ -n "${SPEECHTEXT_TRACES:-}" ] ||
  { echo "SPEECHTEXT_TRACES must name the folder traces are kept in, outside the repository" >&2; exit 64; }
mkdir -p "$SPEECHTEXT_TRACES"
DEST_DIR="$(cd "$SPEECHTEXT_TRACES" && pwd)"
case "$DEST_DIR/" in
  "$REPO_ROOT/"*) echo "SPEECHTEXT_TRACES is inside the repository: a trace holds dictated words" >&2; exit 64 ;;
esac

if [ $# -ge 2 ]; then
  source="$2"
else
  source=$(ls -t "$SOURCE_DIR"/*.json 2>/dev/null | head -1 || true)
  if [ -z "$source" ]; then
    echo "No traces in $SOURCE_DIR — turn on Debug Log › Record traces and dictate first." >&2
    exit 1
  fi
fi

name="${1:-$(basename "$source" .json)}"
mkdir -p "$DEST_DIR"
cp "$source" "$DEST_DIR/$name.json"
echo "Copied $(basename "$source") → $DEST_DIR/$name.json"
echo
python3 - "$DEST_DIR/$name.json" <<'PY'
import json, sys
trace = json.load(open(sys.argv[1]))
setup = trace["setup"]
print(f"app: {setup.get('app')} → {setup.get('destination') or setup.get('app')}, aiMode: {setup['aiMode']}")
for event in trace["events"]:
    detail = event.get("text") or event.get("error")
    print(f"  {event['t']:7.2f}  {event['kind']:<16} {'' if detail is None else detail}")
PY
echo
echo "Review what was pasted. If it is wrong, set \"expectedDocument\" in the file to what"
echo "the document should have held: the replay then fails until the app does that."
