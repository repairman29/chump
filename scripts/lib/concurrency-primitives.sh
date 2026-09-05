#!/usr/bin/env bash
# scripts/lib/concurrency-primitives.sh — INFRA-4608 (INFRA-1966 slice)
#
# Minimal bash concurrency-primitive library: named, flock-backed locks any
# script can acquire/release without hand-rolling `flock` + fd bookkeeping.
#
# Usage:
#   source "$(dirname "$0")/../lib/concurrency-primitives.sh"
#   acquire_lock mylock || exit 1
#   # ... critical section ...
#   release_lock mylock
#
# Public API
#   acquire_lock <name> [timeout_s]   Acquire a named lock. Blocks up to
#                                     timeout_s seconds (default 10; 0 = only
#                                     try once, non-blocking). Returns 0 on
#                                     success, non-zero on failure/timeout.
#   release_lock <name>               Release a previously-acquired lock.
#                                     Returns 0 on success, non-zero if the
#                                     lock was not held by this process.
#
# Implementation notes
# - Backed by flock(1) (via scripts/lib/discover-flock.sh) over a regular
#   file under $CHUMP_LOCK_PRIMITIVE_DIR (default: $TMPDIR/chump-locks or
#   /tmp/chump-locks). One lock file per name; the fd used to hold the lock
#   is tracked in an associative array keyed by name so release_lock can
#   `flock -u` + close the exact fd that acquired it.
# - Locks are per-process: fds do not survive across subshells/processes, so
#   acquire/release must happen in the same shell (source the library, do
#   not run it in a subshell).

if [[ -n "${__CHUMP_LIB_CONCURRENCY_PRIMITIVES_LOADED:-}" ]]; then return 0; fi
__CHUMP_LIB_CONCURRENCY_PRIMITIVES_LOADED=1

_CP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/discover-flock.sh
source "$_CP_SELF_DIR/discover-flock.sh"

: "${CHUMP_LOCK_PRIMITIVE_DIR:=${TMPDIR:-/tmp}/chump-locks}"
mkdir -p "$CHUMP_LOCK_PRIMITIVE_DIR" 2>/dev/null

declare -gA _CP_LOCK_FDS 2>/dev/null || true

# acquire_lock <name> [timeout_s]
acquire_lock() {
    local name="$1" timeout="${2:-10}"
    [[ -n "$name" ]] || { echo "[acquire_lock] ERROR: name required" >&2; return 1; }

    local lockfile="$CHUMP_LOCK_PRIMITIVE_DIR/${name}.lock"
    local fd
    exec {fd}>"$lockfile" || return 1

    if [[ "$timeout" -le 0 ]]; then
        if ! "$FLOCK_BIN" -n "$fd"; then
            eval "exec $fd>&-"
            return 1
        fi
    else
        if ! "$FLOCK_BIN" -w "$timeout" "$fd"; then
            eval "exec $fd>&-"
            return 1
        fi
    fi

    _CP_LOCK_FDS["$name"]="$fd"
    return 0
}

# release_lock <name>
release_lock() {
    local name="$1"
    [[ -n "$name" ]] || { echo "[release_lock] ERROR: name required" >&2; return 1; }

    local fd="${_CP_LOCK_FDS[$name]:-}"
    [[ -n "$fd" ]] || return 1

    "$FLOCK_BIN" -u "$fd" 2>/dev/null
    eval "exec $fd>&-" 2>/dev/null
    unset '_CP_LOCK_FDS[$name]'
    return 0
}
