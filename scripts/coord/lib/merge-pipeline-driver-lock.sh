#!/usr/bin/env bash
# merge-pipeline-driver-lock.sh — RESILIENT-1563.
#
# Exactly-one merge-mutation driver: every path that force-pushes a PR branch,
# calls `gh pr update-branch`, or calls `gh pr merge` must hold THIS SAME named
# flock before mutating — or no-op. Without a shared lock, independently-timed
# organs (merge-serializer, armed-pr-rebaser, keep-mergeable-organ,
# pr-shepherd-daemon) can race the same PR's force-push/merge at once, which is
# the exact "merge-race stalled ships to zero" class RESILIENT-1054 already hit
# once with armed-rebaser vs merge-serializer. RESILIENT-1559 closed the
# override-to-/bin/true axis (an organ disarmed via symlink can't silently
# re-arm); this closes the count axis (two LIVE organs can't both hold the
# mutation critical section at once, regardless of how many are "enabled").
#
# Usage:
#   # shellcheck source=scripts/coord/lib/merge-pipeline-driver-lock.sh
#   source "$(dirname "$0")/lib/merge-pipeline-driver-lock.sh"
#   if merge_pipeline_driver_lock_acquire; then
#       git push origin "$br" --force-with-lease ...
#       merge_pipeline_driver_lock_release
#   else
#       echo "[caller] merge-pipeline-driver.lock contended — no-op this cycle"
#   fi
#
# The lock is held on FD 201 for the lifetime of the calling process (or until
# merge_pipeline_driver_lock_release closes it) — safe to call from a subshell,
# since each subshell gets its own FD table and releases on exit automatically.

MERGE_PIPELINE_DRIVER_LOCK_FD=201

_mpdl_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/discover-flock.sh
source "${_mpdl_lib_dir}/../../lib/discover-flock.sh" 2>/dev/null || {
    command -v flock >/dev/null 2>&1 && FLOCK_BIN="$(command -v flock)" || {
        echo "[merge-pipeline-driver-lock] flock unavailable — treating as no-op pass-through" >&2
        FLOCK_BIN=""
    }
}

# merge_pipeline_driver_lock_acquire [wait_seconds]
# Returns 0 if the lock was acquired (or flock is unavailable — best-effort
# pass-through so a missing binary never silently blocks all merge traffic),
# 1 if contended and the wait timed out.
merge_pipeline_driver_lock_acquire() {
    local wait_s="${1:-${CHUMP_MERGE_PIPELINE_DRIVER_LOCK_WAIT:-30}}"
    local lock_dir="${CHUMP_MERGE_PIPELINE_DRIVER_LOCK_DIR:-${LOCK_DIR:-${CHUMP_REPO_ROOT:-${REPO_ROOT:-.}}/.chump-locks}}"
    local lock_file="${lock_dir}/merge-pipeline-driver.lock"
    mkdir -p "$lock_dir" 2>/dev/null || true

    if [[ -z "${FLOCK_BIN:-}" ]]; then
        return 0
    fi

    eval "exec ${MERGE_PIPELINE_DRIVER_LOCK_FD}>\"\$lock_file\"" || return 1
    if ! "$FLOCK_BIN" -w "$wait_s" "$MERGE_PIPELINE_DRIVER_LOCK_FD" 2>/dev/null; then
        eval "exec ${MERGE_PIPELINE_DRIVER_LOCK_FD}>&-" 2>/dev/null || true
        return 1
    fi
    printf '%s %s\n' "$$" "$(date +%s)" > "${lock_file}.holder" 2>/dev/null || true
    return 0
}

# merge_pipeline_driver_lock_release
# Explicit early release (optional — closing the FD at process/subshell exit
# releases it implicitly too).
merge_pipeline_driver_lock_release() {
    eval "exec ${MERGE_PIPELINE_DRIVER_LOCK_FD}>&-" 2>/dev/null || true
}
