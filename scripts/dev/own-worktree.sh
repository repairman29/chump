#!/usr/bin/env bash
# own-worktree.sh — RESILIENT-256 (2026-08-09)
#
# One command to stop being the agent that destroyed someone else's work.
#
# The 2026-08-09 loss had three causes; the second was that the agent worked
# directly in the PRIMARY checkout that other sessions share. The primary is
# read-mostly. Every agent gets its own worktree — and the reason nobody did
# was that "your own worktree" was a four-command ritual you had to remember,
# while `cd ~/Projects/almanac` was one command you already knew.
#
# This makes the safe path the short path:
#
#   scripts/dev/own-worktree.sh resilient-256
#   → /tmp/<repo>-resilient-256   (created, branch checked out, path printed)
#
# Works in ANY repo, not just chump — the guard it pairs with is installed
# fleet-wide (scripts/setup/install-git-guard-hook.sh).
#
# Usage:
#   scripts/dev/own-worktree.sh <slug> [--base main] [--repo DIR] [--print-only]
#   cd "$(scripts/dev/own-worktree.sh my-work --print-only)"
#
# Idempotent: re-running with the same slug prints the existing worktree.

set -euo pipefail

SLUG=""
BASE=""
REPO_ARG=""
PRINT_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)       BASE="${2:?--base needs a ref}"; shift 2 ;;
        --repo)       REPO_ARG="${2:?--repo needs a path}"; shift 2 ;;
        --print-only) PRINT_ONLY=1; shift ;;
        -h|--help)    sed -n '2,25p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        -*)           echo "unknown flag: $1" >&2; exit 2 ;;
        *)            SLUG="$1"; shift ;;
    esac
done

[[ -n "$SLUG" ]] || { echo "usage: $0 <slug> [--base REF] [--repo DIR] [--print-only]" >&2; exit 2; }

# Slug hygiene: it becomes both a branch name and a /tmp path.
SLUG="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
[[ -n "$SLUG" ]] || { echo "slug reduced to empty after sanitising" >&2; exit 2; }

CWD="${REPO_ARG:-$PWD}"
# Resolve the MAIN checkout, even when invoked from inside a linked worktree.
COMMON="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "not a git repo: $CWD" >&2; exit 2; }
MAIN="$(cd "$COMMON/.." && pwd)"
REPO_NAME="$(basename "$MAIN" | tr '[:upper:]' '[:lower:]')"

if [[ -z "$BASE" ]]; then
    # Prefer the remote's default branch; fall back to whatever main HEAD is on.
    BASE="$(git -C "$MAIN" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    [[ -z "$BASE" ]] && BASE="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
fi

WT="/tmp/${REPO_NAME}-${SLUG}"
BRANCH="${SLUG}"

# Already there? Print and leave it alone — never re-create over live work.
if [[ -d "$WT" ]]; then
    [[ "$PRINT_ONLY" -eq 1 ]] || echo "[own-worktree] reusing existing worktree" >&2
    printf '%s\n' "$WT"
    exit 0
fi

if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$MAIN" worktree add "$WT" "$BRANCH" >&2
else
    git -C "$MAIN" worktree add "$WT" -b "$BRANCH" "$BASE" >&2
fi

if [[ "$PRINT_ONLY" -eq 0 ]]; then
    {
        echo "[own-worktree] $WT  (branch $BRANCH, from $BASE)"
        echo "[own-worktree] cd \"$WT\"  — and commit early: uncommitted work is the"
        echo "[own-worktree] one class git cannot recover (RESILIENT-256)."
    } >&2
fi
printf '%s\n' "$WT"
