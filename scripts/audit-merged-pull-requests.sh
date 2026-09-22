#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Every merged pull request's merge commit must be an ancestor of main.
#
# GitHub reports a merge as successful whether or not main ever sees it: a pull
# request based on another branch merges into *that* branch, and if the branch
# has already landed, the work is merged, green, and gone. That is #43 — PR #41
# merged into a branch main had stopped following seven minutes earlier.
#
# CI cannot see it, because CI runs on the pull request's own range and the range
# is fine. So the check is made afterwards, over every merged pull request there
# has ever been. .github/workflows/ci.yml refuses the shape up front; this script
# is what says whether the refusal has ever been evaded.
#
#   scripts/audit-merged-pull-requests.sh
#
# Exits 0 when every merged pull request is in main, 1 when any is not — or when
# any could not be judged, since an unaudited pull request is not a clean one. A
# miss whose work has since landed some other way is listed but does not fail the
# run; see `accounted_for` below.

set -euo pipefail

limit=500
remote=origin

while [ $# -gt 0 ]; do
  case "$1" in
    --limit) limit="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    -h|--help)
      sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v gh > /dev/null || { echo "The GitHub CLI (gh) is not installed." >&2; exit 2; }

# Pull requests whose merge commit will never be an ancestor of main, and why that
# is settled rather than outstanding.
#
# A merge that missed main cannot be brought back after the fact: the work returns
# as a *different* commit through a fresh pull request, so the original merge commit
# stays outside main for good. Left alone the audit would report it on every run
# from now on, and a check that always fails is a check nobody reads.
#
# One entry per pull request: the number, whitespace, and where the work landed.
# Add one only when that has actually happened.
accounted_for=(
  "41  came back as an equivalent commit in #62 — see issue #43"
)

# The comparison is against the remote's main, not a local branch that may be days
# behind — a stale main turns every recent pull request into a false alarm.
git fetch --quiet "$remote" main

merged=$(gh pr list --state merged --limit "$limit" --json number,mergeCommit,title \
  --jq '.[] | "\(.number)|\(.mergeCommit.oid // "")|\(.title)"')

count=$(printf '%s' "$merged" | grep -c '^' || true)
if [ "$count" -ge "$limit" ]; then
  echo "Warning: $count merged pull requests is the --limit, so older ones went unread." >&2
  echo "Re-run with a higher --limit." >&2
fi

lost=""
settled=""
unknown=""

while IFS='|' read -r number oid title; do
  [ -n "$number" ] || continue

  if [ -z "$oid" ]; then
    # A pull request can be marked merged with no merge commit recorded — merged by
    # hand, or the commit rewritten away since. Either way it is not something this
    # script may quietly pass.
    unknown="$unknown  PR #$number  $title (no merge commit recorded)"$'\n'
    continue
  fi

  if ! git cat-file -e "$oid^{commit}" 2> /dev/null; then
    # The branch was deleted after the merge, so the commit may not be in this clone.
    # GitHub still serves it by hash.
    git fetch --quiet "$remote" "$oid" 2> /dev/null || true
  fi

  if ! git cat-file -e "$oid^{commit}" 2> /dev/null; then
    unknown="$unknown  PR #$number  $title ($oid could not be fetched)"$'\n'
    continue
  fi

  if ! git merge-base --is-ancestor "$oid" "$remote/main"; then
    note=""
    for entry in ${accounted_for[@]+"${accounted_for[@]}"}; do
      case "$entry" in
        "$number "*|"$number"$'\t'*) note="${entry#"$number"}" ;;
      esac
    done
    if [ -n "$note" ]; then
      settled="$settled  PR #$number  $title"$'\n      '"$(printf '%s' "$note" | sed 's/^[[:space:]]*//')"$'\n'
    else
      lost="$lost  PR #$number  $title"$'\n      '"$oid"$'\n'
    fi
  fi
done <<< "$merged"

echo "Audited $count merged pull requests against $remote/main."

if [ -n "$settled" ]; then
  echo
  echo "Not in main, and accounted for:"
  printf '%s' "$settled"
fi

if [ -n "$unknown" ]; then
  echo
  echo "These could not be judged:"
  printf '%s' "$unknown"
fi

if [ -n "$lost" ]; then
  echo
  echo "These merged pull requests are NOT in main:"
  printf '%s' "$lost"
  echo
  echo "Each one merged into a branch rather than into main. The commits are still in"
  echo "refs/pull/<number>/head — cherry-pick them onto main through a fresh pull request."
  exit 1
fi

if [ -n "$unknown" ]; then
  exit 1
fi

if [ -n "$settled" ]; then
  echo "Nothing outstanding."
else
  echo "Every one of them is in main."
fi
