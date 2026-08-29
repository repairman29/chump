#!/usr/bin/env bash
# paramedic-safe-squash-check.sh — INFRA-1463
#
# Safety pre-check for the "reset --soft <main>" squash recipe documented in
# docs/process/CLAUDE_GOTCHAS.md ("Tangled-stack rebase recipe") and used by
# the paramedic SQUASH_INIT_LEAK flow. `git reset --soft <main>` moves HEAD
# without touching the index/working tree, so any file `main` gained since
# the branch's base looks like a DELETION when the resulting commit is
# staged — a real PR (#2068) squashed this way silently deleted 38 test
# files from a sibling PR. See docs/process/PARAMEDIC_SAFETY_RULES.md.
#
# Usage: paramedic-safe-squash-check.sh <branch-ref> [<main-ref>]
# Exit 0 = safe to reset-squash. Exit 1 = ABORT, main has diverged too far.
set -euo pipefail

BRANCH_REF="${1:?usage: paramedic-safe-squash-check.sh <branch-ref> [<main-ref>]}"
MAIN_REF="${2:-origin/main}"
THRESHOLD="${CHUMP_SQUASH_SAFETY_MAX_ADDITIONS:-5}"

if ! git rev-parse --verify --quiet "$BRANCH_REF" >/dev/null; then
    echo "ERROR: branch ref '$BRANCH_REF' does not resolve" >&2
    exit 2
fi
if ! git rev-parse --verify --quiet "$MAIN_REF" >/dev/null; then
    echo "ERROR: main ref '$MAIN_REF' does not resolve" >&2
    exit 2
fi

ADDED_FILES="$(git diff --name-status "$BRANCH_REF" "$MAIN_REF" 2>/dev/null | awk '$1 ~ /^A/ {print $2}')"
ADDED_COUNT=0
if [[ -n "$ADDED_FILES" ]]; then
    ADDED_COUNT="$(printf '%s\n' "$ADDED_FILES" | wc -l | tr -d ' ')"
fi

if [[ "$ADDED_COUNT" -gt "$THRESHOLD" ]]; then
    echo "ABORT: $MAIN_REF has $ADDED_COUNT file additions since $BRANCH_REF diverged (threshold=$THRESHOLD)." >&2
    echo "A 'git reset --soft $MAIN_REF' squash here would stage every one of these as a DELETION." >&2
    echo "Use 'git rebase -i --autosquash $MAIN_REF' or 'git filter-repo' with an explicit commit-drop instead." >&2
    printf '%s\n' "$ADDED_FILES" | sed 's/^/  would delete: /' >&2
    exit 1
fi

echo "OK: $ADDED_COUNT file addition(s) on $MAIN_REF since $BRANCH_REF diverged (threshold=$THRESHOLD) — safe to reset-squash."
exit 0
