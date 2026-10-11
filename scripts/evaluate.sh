#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the audio corpus (#80) through every speech engine and writes one run folder,
# docs/testing-runs/<date>/: summary.md (the engine × clip table), results-*.json and
# the streaming engines' traces.
#
#   ELEVENLABS_API_KEY=… OPENAI_API_KEY=… GROQ_API_KEY=… \
#     scripts/evaluate.sh <corpus-dir>            cloud engines, then local ones
#   scripts/evaluate.sh <corpus-dir> --cloud      cloud engines only
#   scripts/evaluate.sh <corpus-dir> --local      local engines only (no keys needed)
#
# <corpus-dir> holds <clip>.wav for the descriptions in SpeechText/SpeechTextTests/Audio/.
# The audio stays out of the repository: it is someone's voice.
#
# Keys are read from this environment only, never from the app's settings — they may be
# other keys than the app's. An engine without its key is a "no key" row, not a failure.
# Optional: SPEECHTEXT_ENGINES=openAI/gpt-live-transcribe,… and SPEECHTEXT_CLIPS=a,b.
#
# The cloud half costs cents and takes about as long as the clips; the local half needs
# the models installed (Settings › Local), and a model's first load after a build may
# take minutes — it is reported apart from the stop-to-text time.
set -euo pipefail

if [ $# -lt 1 ]; then
  sed -n '5,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

corpus="$(cd "$1" && pwd)"
mode="${2:-all}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
# SPEECHTEXT_RUN_DIR=<an earlier run> adds to it: the clips run now replace their own
# rows, every other row stays — a clip recorded after a run needs no second full run.
run_dir="${SPEECHTEXT_RUN_DIR:-$repo/docs/testing-runs/$(date +%Y-%m-%d_%H-%M)}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
derived=/tmp/st-dd-evaluation
project="$repo/SpeechText/SpeechText.xcodeproj"
mkdir -p "$run_dir"
status=0

if [ "$mode" != "--local" ]; then
  echo "▸ Cloud engines (LiveProviderTests)…"
  # An unhosted test bundle does not inherit this environment; xcodebuild passes
  # TEST_RUNNER_<NAME> through to it as <NAME>.
  TEST_RUNNER_SPEECHTEXT_LIVE=1 \
  TEST_RUNNER_SPEECHTEXT_CORPUS="$corpus" \
  TEST_RUNNER_SPEECHTEXT_RUN_DIR="$run_dir" \
  TEST_RUNNER_SPEECHTEXT_ENGINES="${SPEECHTEXT_ENGINES:-}" \
  TEST_RUNNER_SPEECHTEXT_CLIPS="${SPEECHTEXT_CLIPS:-}" \
  TEST_RUNNER_ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-}" \
  TEST_RUNNER_OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
  TEST_RUNNER_GROQ_API_KEY="${GROQ_API_KEY:-}" \
    xcodebuild test -project "$project" -scheme SpeechText -destination 'platform=macOS' \
      -derivedDataPath "$derived" \
      -only-testing:SpeechTextTests/LiveProviderTests >"$run_dir/cloud.log" 2>&1 || status=1
  grep -E "error: -\[|Executed [0-9]+ tests?" "$run_dir/cloud.log" | tail -20 || true
fi

if [ "$mode" != "--cloud" ]; then
  echo "▸ Local engines (SpeechTextEvaluation)…"
  xcodebuild build -project "$project" -scheme SpeechTextEvaluation -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$derived" >"$run_dir/local-build.log" 2>&1 \
    || { echo "build failed — see $run_dir/local-build.log" >&2; exit 1; }
  args=(--corpus "$corpus" --run-dir "$run_dir")
  [ -n "${SPEECHTEXT_ENGINES:-}" ] && args+=(--engines "$SPEECHTEXT_ENGINES")
  [ -n "${SPEECHTEXT_CLIPS:-}" ] && args+=(--clips "$SPEECHTEXT_CLIPS")
  "$derived/Build/Products/Release/SpeechTextEvaluation" "${args[@]}" || status=1
fi

echo
echo "Summary: ${run_dir#"$repo/"}/summary.md"
exit $status
