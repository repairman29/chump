#!/usr/bin/env bash
# fleet-cleanup.sh — orchestrate all periodic cleanup tasks for fleet hygiene.
#
# Runs a series of safe cleanup operations in sequence:
#   1. stale-lease-reaper.sh — remove expired session leases from .chump-locks/
#   2. stale-gap-worktree-reaper.sh — remove stale /tmp worktrees from completed gaps
#   3. worktree-prune.sh — clean up .claude/worktrees/ from merged PRs
#
# This is the single entry point for fleet hygiene. Schedule it to run
# every 30 minutes via launchd (com.chump.fleet-cleanup.plist).
#
# Usage:
#   scripts/coord/fleet-cleanup.sh                 # dry-run (safe)
#   scripts/coord/fleet-cleanup.sh --execute       # actually delete
#
# Exit: 0 if all OK, 1+ if any cleanup task has errors

set -euo pipefail

DRY_RUN=1
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute) DRY_RUN=0 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Counters
total_deleted=0
total_skipped=0
total_errors=0

echo "[fleet-cleanup] Starting periodic cleanup suite..."
echo "[fleet-cleanup] $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Clean stale leases
if [ -x "$REPO_ROOT/scripts/coord/stale-lease-reaper.sh" ]; then
    echo "[fleet-cleanup] --- Phase 1: stale leases ---"
    set +e
    if [ "$DRY_RUN" = 1 ]; then
        "$REPO_ROOT/scripts/coord/stale-lease-reaper.sh" 2>&1 | tee /tmp/fleet-cleanup-leases.log
    else
        "$REPO_ROOT/scripts/coord/stale-lease-reaper.sh" --execute 2>&1 | tee /tmp/fleet-cleanup-leases.log
    fi
    lease_result=$?
    set -e

    # Extract counts from output
    if grep -q "summary:" /tmp/fleet-cleanup-leases.log; then
        deleted=$(grep "summary:" /tmp/fleet-cleanup-leases.log | grep -o "deleted=[0-9]*" | cut -d= -f2)
        skipped=$(grep "summary:" /tmp/fleet-cleanup-leases.log | grep -o "skipped=[0-9]*" | cut -d= -f2)
        errors=$(grep "summary:" /tmp/fleet-cleanup-leases.log | grep -o "errors=[0-9]*" | cut -d= -f2)
        total_deleted=$((total_deleted + deleted))
        total_skipped=$((total_skipped + skipped))
        total_errors=$((total_errors + errors))
    fi
fi

# 2. Clean stale /tmp worktrees
if [ -x "$REPO_ROOT/scripts/coord/stale-gap-worktree-reaper.sh" ]; then
    echo "[fleet-cleanup] --- Phase 2: stale /tmp worktrees ---"
    set +e
    if [ "$DRY_RUN" = 1 ]; then
        "$REPO_ROOT/scripts/coord/stale-gap-worktree-reaper.sh" 2>&1 | tee /tmp/fleet-cleanup-worktrees.log
    else
        "$REPO_ROOT/scripts/coord/stale-gap-worktree-reaper.sh" --execute 2>&1 | tee /tmp/fleet-cleanup-worktrees.log
    fi
    wt_result=$?
    set -e

    # Extract counts
    if grep -q "summary:" /tmp/fleet-cleanup-worktrees.log; then
        deleted=$(grep "summary:" /tmp/fleet-cleanup-worktrees.log | grep -o "deleted=[0-9]*" | cut -d= -f2)
        skipped=$(grep "summary:" /tmp/fleet-cleanup-worktrees.log | grep -o "skipped=[0-9]*" | cut -d= -f2)
        errors=$(grep "summary:" /tmp/fleet-cleanup-worktrees.log | grep -o "errors=[0-9]*" | cut -d= -f2)
        total_deleted=$((total_deleted + deleted))
        total_skipped=$((total_skipped + skipped))
        total_errors=$((total_errors + errors))
    fi
fi

# 3. Clean .claude/worktrees/ (optional, only if --execute)
if [ "$DRY_RUN" = 0 ] && [ -x "$REPO_ROOT/scripts/coord/worktree-prune.sh" ]; then
    echo "[fleet-cleanup] --- Phase 3: .claude/worktrees cleanup ---"
    set +e
    "$REPO_ROOT/scripts/coord/worktree-prune.sh" --execute 2>&1 | tee /tmp/fleet-cleanup-prune.log
    prune_result=$?
    set -e
fi

# Summary
echo "[fleet-cleanup] === SUMMARY ==="
echo "[fleet-cleanup] Total deleted: $total_deleted"
echo "[fleet-cleanup] Total skipped: $total_skipped"
echo "[fleet-cleanup] Total errors: $total_errors"
echo "[fleet-cleanup] Mode: $([ "$DRY_RUN" = 1 ] && echo 'DRY-RUN' || echo 'EXECUTE')"
echo "[fleet-cleanup] Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

exit "$total_errors"
