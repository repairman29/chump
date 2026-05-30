#!/usr/bin/env bash
# scripts/ops/curator-sentinel-reaper.sh — META-165
#
# Stale-sentinel reaper: runs every 5 min via launchd
# (com.chump.curator-sentinel-reaper.plist). Iterates
# .chump-locks/.curator-opus-*.lock files and removes any whose PID is dead
# (via _curator_sentinel_alive) OR whose mtime is > 30 minutes old.
#
# Without this reaper, a curator that crashes without firing its EXIT trap
# leaves a stale lock file. broadcast.sh's META-158 FEEDBACK fan-out would
# then route proposals to a dead inbox indefinitely.
#
# Emits kind=curator_sentinel_reaped to ambient.jsonl for each removed file.
#
# Env:
#   CHUMP_LOCK_DIR         override for .chump-locks/ (test isolation)
#   CHUMP_AMBIENT_LOG      override for ambient.jsonl
#   CHUMP_SENTINEL_STALE_SECS  mtime threshold in seconds (default: 1800 = 30 min)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SENTINEL_LIB="$REPO_ROOT/scripts/coord/lib/curator-sentinel.sh"
STALE_MTIME_SECS="${CHUMP_SENTINEL_STALE_SECS:-1800}"

if [[ ! -f "$SENTINEL_LIB" ]]; then
    echo "[curator-sentinel-reaper] WARN: sentinel lib missing at $SENTINEL_LIB" >&2
    exit 0
fi
# shellcheck source=scripts/coord/lib/curator-sentinel.sh
# shellcheck disable=SC1091  # dynamic path resolved at runtime via SENTINEL_LIB variable
source "$SENTINEL_LIB"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

now=$(date +%s)
reaped=0

for sentinel in "$LOCK_DIR"/.curator-opus-*.lock; do
    [[ -e "$sentinel" ]] || continue

    # Extract role from filename: .curator-opus-<role>.lock
    basename_s="${sentinel##*/}"
    role="${basename_s#.curator-opus-}"
    role="${role%.lock}"

    dead=0
    reason=""

    # Check 1: PID alive?
    if ! _curator_sentinel_alive "$role" 2>/dev/null; then
        dead=1
        reason="pid_dead"
    fi

    # Check 2: mtime > STALE_MTIME_SECS (stale even if PID somehow reused)?
    if [[ "$dead" == "0" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            mtime=$(stat -f %m "$sentinel" 2>/dev/null || echo 0)
        else
            mtime=$(stat -c %Y "$sentinel" 2>/dev/null || echo 0)
        fi
        age=$(( now - mtime ))
        if (( age > STALE_MTIME_SECS )); then
            dead=1
            reason="stale_mtime_${age}s"
        fi
    fi

    if [[ "$dead" == "1" ]]; then
        rm -f "$sentinel" 2>/dev/null || true
        ts="$(_now_iso)"
        printf '{"ts":"%s","kind":"curator_sentinel_reaped","role":"%s","reason":"%s","session":"curator-sentinel-reaper"}\n' \
            "$ts" "$role" "$reason" >> "$AMBIENT" 2>/dev/null || true
        echo "[curator-sentinel-reaper] reaped .curator-opus-${role}.lock reason=${reason}"
        reaped=$(( reaped + 1 ))
    fi
done

echo "[curator-sentinel-reaper] done: reaped=${reaped} ts=$(_now_iso)"
