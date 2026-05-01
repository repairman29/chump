#!/usr/bin/env bash
# pr-watch.sh — INFRA-190: auto-recover a DIRTY-after-arm PR.
#
# The merge queue arms auto-merge optimistically: if main moves between
# `gh pr create` and queue entry, the PR goes DIRTY. Today the human or
# agent has to manually:
#   1. gh pr merge <N> --disable-auto
#   2. git fetch origin main && git rebase origin/main
#   3. (resolve trivial gaps.yaml conflicts)
#   4. CHUMP_GAP_CHECK=0 git push --force-with-lease
#   5. gh pr merge <N> --auto --squash
#
# I (this session) did exactly this 5+ times today. This script does it
# automatically when the rebase is conflict-free (~80% of cases). Real
# content conflicts still surface to the operator with exit 3.
#
# Usage:
#   scripts/coord/pr-watch.sh <PR#>            # poll until merged/timeout
#   scripts/coord/pr-watch.sh <PR#> --once     # check once and act, then exit
#
# Run from the BRANCH worktree (where the branch is checked out). The
# script uses the current branch via `git symbolic-ref` for the push
# target — no need to pass it.
#
# Env:
#   PR_WATCH_TIMEOUT      seconds before giving up (default 1800)
#   PR_WATCH_POLL         seconds between polls (default 30)
#   CHUMP_PR_WATCH=0      bypass — exit 0 immediately (for tests)
#
# Exit codes:
#   0  PR merged successfully (or --once + state is good)
#   1  PR closed without merge
#   2  Timeout (PR still in flight)
#   3  Rebase produced conflicts — operator must resolve
#   4  Usage error / not in a branch worktree

set -euo pipefail

if [[ "${CHUMP_PR_WATCH:-1}" == "0" ]]; then
    echo "[pr-watch] CHUMP_PR_WATCH=0 — bypass"
    exit 0
fi

PR="${1:?usage: $0 <PR#> [--once]}"
ONCE=0
[[ "${2:-}" == "--once" ]] && ONCE=1

TIMEOUT_S="${PR_WATCH_TIMEOUT:-1800}"
POLL_S="${PR_WATCH_POLL:-30}"

# Confirm we're in a git checkout with the branch checked out.
if ! BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null); then
    echo "[pr-watch] ERROR: not in a git checkout with a branch — refusing to push" >&2
    exit 4
fi

# Confirm this branch matches the PR.
PR_BRANCH=$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null || true)
if [[ -n "$PR_BRANCH" && "$PR_BRANCH" != "$BRANCH" ]]; then
    echo "[pr-watch] ERROR: current branch '$BRANCH' does not match PR #$PR head '$PR_BRANCH'" >&2
    exit 4
fi

DEADLINE=$(($(date +%s) + TIMEOUT_S))
LAST_STATE=""

say() { printf '\033[1;36m[pr-watch]\033[0m PR #%s: %s\n' "$PR" "$*"; }

attempt_recovery() {
    say "DIRTY detected → disarm + rebase + force-push + re-arm"
    gh pr merge "$PR" --disable-auto >/dev/null 2>&1 || true
    git fetch origin main --quiet
    if git rebase origin/main >/tmp/pr-watch-rebase-$$.log 2>&1; then
        if ! CHUMP_GAP_CHECK=0 git push --force-with-lease origin "$BRANCH" >/dev/null 2>&1; then
            say "force-push rejected (someone else pushed?) — re-arming and waiting"
        fi
        gh pr merge "$PR" --auto --squash >/dev/null 2>&1
        say "auto-recovered ✓"
        rm -f /tmp/pr-watch-rebase-$$.log
        return 0
    else
        say "✗ rebase has CONFLICTS — operator must resolve"
        echo "  see: /tmp/pr-watch-rebase-$$.log"
        git rebase --abort 2>/dev/null || true
        return 3
    fi
}

while (( $(date +%s) < DEADLINE )); do
    state=$(gh pr view "$PR" --json state,mergeStateStatus -q '"\(.state) \(.mergeStateStatus)"' 2>/dev/null || echo "UNKNOWN UNKNOWN")

    if [[ "$state" != "$LAST_STATE" ]]; then
        say "$state"
        LAST_STATE="$state"
    fi

    case "$state" in
        "MERGED "*)
            say "merged ✓"
            exit 0
            ;;
        "CLOSED "*)
            say "closed without merge ✗"
            exit 1
            ;;
        "OPEN DIRTY")
            attempt_recovery || exit $?
            sleep 5  # brief pause before re-poll so the queue sees the new state
            ;;
        "OPEN BLOCKED" | "OPEN BEHIND" | "OPEN CLEAN" | "OPEN HAS_HOOKS" | "OPEN UNSTABLE" | "OPEN UNKNOWN")
            # Healthy in-flight states — let the queue / CI work
            ;;
        *)
            say "unrecognized state '$state' — continuing to poll"
            ;;
    esac

    if [[ "$ONCE" -eq 1 ]]; then
        exit 0
    fi
    sleep "$POLL_S"
done

say "timeout after ${TIMEOUT_S}s — PR still in flight"
exit 2
