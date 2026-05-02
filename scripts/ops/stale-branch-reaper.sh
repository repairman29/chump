#!/usr/bin/env bash
# stale-branch-reaper.sh — Auto-delete remote branches with no open PR and no
# recent commits.
#
# Sister to stale-pr-reaper.sh (which closes stale PRs whose gaps landed on
# main). This one closes the *other* leak: branches that were pushed but
# never opened a PR (or whose PR was closed without merging) and now sit
# around forever burning ref-list bandwidth.
#
# What it does:
#   1. Lists all remote branches matching configured patterns (default: claude/*
#      and worktree-*).
#   2. For each: checks (a) is there an open PR with this head? (b) when was
#      the last commit?
#   3. Deletes the remote ref if NO open PR AND last commit is older than
#      STALE_DAYS_THRESHOLD.
#
# Usage:
#   ./scripts/ops/stale-branch-reaper.sh             # dry-run by default
#   ./scripts/ops/stale-branch-reaper.sh --execute   # actually delete refs
#
# Environment:
#   REMOTE                 git remote (default: origin)
#   BASE                   protected base branch — never deleted (default: main)
#   STALE_DAYS_THRESHOLD   days since last commit before a branch is reapable
#                          (default: 14)
#   BRANCH_PATTERNS        space-separated git-ref globs to consider
#                          (default: "claude/* worktree-*")

set -euo pipefail

# INFRA-120: shared instrumentation (heartbeat + ambient reaper_run event +
# log rotation). Watchdog reads /tmp/chump-reaper-branch.heartbeat.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup branch
reaper_rotate_log /tmp/chump-stale-branch-reaper.out.log
reaper_rotate_log /tmp/chump-stale-branch-reaper.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
STALE_DAYS_THRESHOLD="${STALE_DAYS_THRESHOLD:-14}"
BRANCH_PATTERNS="${BRANCH_PATTERNS:-claude/* worktree-*}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== stale-branch-reaper (remote: $REMOTE, threshold: ${STALE_DAYS_THRESHOLD}d) ==="
[[ $EXECUTE -eq 0 ]] && info "Dry-run mode — pass --execute to actually delete refs."

git fetch "$REMOTE" --prune --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE — aborting."; exit 1
}

# Branches with an open PR are safe regardless of age.
OPEN_PR_BRANCHES=$(gh pr list --state open --json headRefName \
    --jq '.[].headRefName' 2>/dev/null | sort -u || true)

NOW_EPOCH=$(date +%s)
THRESHOLD_SECS=$(( STALE_DAYS_THRESHOLD * 86400 ))

REAPED=0
SKIPPED_PR=0
SKIPPED_FRESH=0

# Build the ref-list pattern args for git for-each-ref.
PATTERN_ARGS=()
for pat in $BRANCH_PATTERNS; do
    PATTERN_ARGS+=("refs/remotes/$REMOTE/$pat")
done

while IFS=$'\t' read -r REFNAME COMMITTERDATE; do
    BRANCH="${REFNAME#refs/remotes/$REMOTE/}"

    # Never touch the base.
    if [[ "$BRANCH" == "$BASE" ]]; then continue; fi

    # Skip if there's an open PR for this branch.
    if echo "$OPEN_PR_BRANCHES" | grep -qx "$BRANCH"; then
        SKIPPED_PR=$((SKIPPED_PR + 1))
        continue
    fi

    # Skip if last commit is fresher than threshold.
    AGE_SECS=$(( NOW_EPOCH - COMMITTERDATE ))
    if [[ "$AGE_SECS" -lt "$THRESHOLD_SECS" ]]; then
        SKIPPED_FRESH=$((SKIPPED_FRESH + 1))
        continue
    fi

    AGE_DAYS=$(( AGE_SECS / 86400 ))
    info "Stale: $BRANCH (last commit ${AGE_DAYS}d ago, no open PR)"

    if [[ $EXECUTE -eq 1 ]]; then
        if git push "$REMOTE" --delete "$BRANCH" 2>/dev/null; then
            green "  Deleted $REMOTE/$BRANCH."
            REAPED=$((REAPED + 1))
        else
            warn "Failed to delete $REMOTE/$BRANCH (protected? already gone?)"
        fi
    else
        dry "git push $REMOTE --delete $BRANCH"
        REAPED=$((REAPED + 1))
    fi
done < <(git for-each-ref --format='%(refname)%09%(committerdate:unix)' \
            "${PATTERN_ARGS[@]}" 2>/dev/null)

echo ""
green "=== reaper done: $REAPED reaped, $SKIPPED_PR skipped (open PR), $SKIPPED_FRESH skipped (fresh) ==="

# INFRA-120: emit heartbeat + reaper_run event so the watchdog and other
# agents can see this reaper completed.
trap - EXIT
reaper_finish ok "{\"reaped\":$REAPED,\"skipped_pr\":$SKIPPED_PR,\"skipped_fresh\":$SKIPPED_FRESH,\"execute\":$EXECUTE}"
