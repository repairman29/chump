#!/usr/bin/env bash
# scripts/coord/lib/merge-pipeline-lock.sh — RESILIENT-1563
#
# ONE shared flock authority for every force-push / update-branch / pr-merge
# mutation path in the fleet. Any organ that force-pushes a PR branch, calls
# `gh pr update-branch`, or calls `gh pr merge` must acquire this lock first
# — if another organ already holds it, the caller MUST no-op rather than
# mutate in parallel. This is the count-axis complement to RESILIENT-1559
# (the override-to-/bin/true axis, "can this organ be silenced") — this
# lock answers "can only ONE organ ever be mutating the merge pipeline at
# a time", independent of how many organs are *enabled*.
#
# Usage:
#   # shellcheck source=scripts/coord/lib/merge-pipeline-lock.sh
#   source "$(dirname "$0")/lib/merge-pipeline-lock.sh"
#   if merge_pipeline_lock_acquire; then
#       # ... force-push / update-branch / pr merge here ...
#       merge_pipeline_lock_release
#   else
#       echo "[caller] merge-pipeline-driver.lock held elsewhere — no-op" >&2
#   fi
#
# Env knobs:
#   CHUMP_MERGE_PIPELINE_LOCK_FILE       — override lock path (tests)
#   CHUMP_MERGE_PIPELINE_LOCK_WAIT_SECS  — 0 (default) = non-blocking (flock -n);
#                                          >0 = block up to N seconds (flock -w N)

_MPL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/discover-flock.sh
source "$_MPL_LIB_DIR/../../lib/discover-flock.sh" 2>/dev/null || {
    if command -v flock >/dev/null 2>&1; then
        FLOCK_BIN="$(command -v flock)"
    else
        echo "[merge-pipeline-lock] flock unavailable — refusing to claim authority" >&2
        FLOCK_BIN=""
    fi
}

_mpl_repo_root() {
    git -C "$_MPL_LIB_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$_MPL_LIB_DIR/../../.." && pwd)
}

if [[ -z "${MERGE_PIPELINE_LOCK_FILE:-}" ]]; then
    MERGE_PIPELINE_LOCK_FILE="${CHUMP_MERGE_PIPELINE_LOCK_FILE:-$(_mpl_repo_root)/.chump-locks/merge-pipeline-driver.lock}"
fi
MERGE_PIPELINE_LOCK_WAIT_SECS="${CHUMP_MERGE_PIPELINE_LOCK_WAIT_SECS:-0}"

# Fixed, high fd to avoid collisions with per-script locks (commonly 9/200).
_MPL_FD=219

# merge_pipeline_lock_acquire — non-blocking by default. Returns 0 (lock
# held, caller may proceed) or 1 (lock unavailable — caller MUST no-op).
merge_pipeline_lock_acquire() {
    [[ -n "$FLOCK_BIN" ]] || return 1
    mkdir -p "$(dirname "$MERGE_PIPELINE_LOCK_FILE")" 2>/dev/null
    exec 219>"$MERGE_PIPELINE_LOCK_FILE" || return 1
    if [[ "$MERGE_PIPELINE_LOCK_WAIT_SECS" -gt 0 ]]; then
        "$FLOCK_BIN" -w "$MERGE_PIPELINE_LOCK_WAIT_SECS" "$_MPL_FD" || { exec 219>&- 2>/dev/null; return 1; }
    else
        "$FLOCK_BIN" -n "$_MPL_FD" || { exec 219>&- 2>/dev/null; return 1; }
    fi
    return 0
}

merge_pipeline_lock_release() {
    exec 219>&- 2>/dev/null || true
}
