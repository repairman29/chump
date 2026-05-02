# shellcheck shell=bash
# reaper-instrumentation.sh — shared helpers for stale-*-reaper.sh scripts.
#
# Provides three things every reaper needs (INFRA-120, 2026-05-01):
#   1. reaper_emit_run NAME STATUS COUNTS_JSON
#        Emits one `kind=reaper_run` event into .chump-locks/ambient.jsonl
#        AND stamps a heartbeat file at /tmp/chump-reaper-NAME.heartbeat
#        (the watchdog reads the heartbeat to detect missed runs).
#
#   2. reaper_rotate_log PATH MAX_BYTES
#        Truncates a log file to the most-recent MAX_BYTES (default 5MB) by
#        rotating PATH → PATH.1 once it exceeds the cap. Cheap; safe to call
#        every run. Keeps two generations on disk (PATH and PATH.1).
#
#   3. reaper_setup NAME
#        One-line setup that resolves the main repo root (works from a
#        worktree), exports REAPER_NAME / REAPER_REPO_ROOT / REAPER_LOCK_DIR
#        / REAPER_HEARTBEAT, and starts a wall-clock timer. Pair with
#        reaper_finish to emit a single reaper_run event with elapsed seconds.
#
# Source from the top of every reaper:
#   source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
#   reaper_setup pr            # or worktree, branch, etc.
#   ... do work, accumulate counts ...
#   reaper_finish ok '{"closed":3,"warned":1}'
#
# Designed to be Bash 3.2+ compatible (macOS default) and dependency-light:
# uses python3 for JSON only when available, falls back to a hand-rolled
# emitter so heartbeat stamping always works (the watchdog grades on the
# heartbeat, not on JSON validity).

# Resolve main repo root from any worktree. Linked worktrees have a separate
# --show-toplevel but share --git-common-dir, so the canonical root is the
# parent of --git-common-dir.
_reaper_main_repo() {
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$common" == ".git" ]]; then
        git rev-parse --show-toplevel 2>/dev/null || pwd
    else
        # common is .git or /abs/path/.git; main repo root is its parent.
        (cd "$common/.." && pwd)
    fi
}

# reaper_setup NAME — call once at the top of a reaper script.
reaper_setup() {
    REAPER_NAME="${1:?reaper_setup needs a name}"
    REAPER_REPO_ROOT="$(_reaper_main_repo)"
    REAPER_LOCK_DIR="$REAPER_REPO_ROOT/.chump-locks"
    REAPER_HEARTBEAT="/tmp/chump-reaper-${REAPER_NAME}.heartbeat"
    REAPER_START_EPOCH="$(date +%s)"
    mkdir -p "$REAPER_LOCK_DIR" 2>/dev/null || true
}

# reaper_rotate_log PATH [MAX_BYTES]
# Rotate PATH → PATH.1 when it exceeds MAX_BYTES (default 5_242_880 = 5 MB).
# A no-op if the file doesn't exist or is under cap. Keeps exactly one
# generation; the launchd-managed /tmp logs are noisy and not historically
# valuable.
reaper_rotate_log() {
    local path="$1"
    local max="${2:-5242880}"
    [[ -f "$path" ]] || return 0
    local size
    if size=$(stat -f%z "$path" 2>/dev/null); then
        :  # macOS / BSD stat
    else
        size=$(stat -c%s "$path" 2>/dev/null || echo 0)
    fi
    if [[ "${size:-0}" -gt "$max" ]]; then
        mv -f "$path" "${path}.1" 2>/dev/null || true
        : > "$path" 2>/dev/null || true
    fi
}

# reaper_emit_run NAME STATUS COUNTS_JSON [DURATION_SECS]
# Append a kind=reaper_run event to ambient.jsonl AND stamp the heartbeat.
# COUNTS_JSON is a free-form JSON object (e.g. '{"closed":3,"warned":1}').
# Heartbeat is stamped FIRST so the watchdog still sees a recent run even if
# the JSON emit fails on a corrupted ambient.jsonl.
reaper_emit_run() {
    local name="${1:?reaper_emit_run needs name}"
    local status="${2:?reaper_emit_run needs status}"
    local counts="${3:-}"
    [[ -z "$counts" ]] && counts='{}'
    local duration="${4:-0}"

    local heartbeat="/tmp/chump-reaper-${name}.heartbeat"
    local lock_dir="${REAPER_LOCK_DIR:-$(_reaper_main_repo)/.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 1. Stamp heartbeat (always, even on dry runs).
    {
        echo "ts=$ts"
        echo "status=$status"
        echo "duration=$duration"
        echo "counts=$counts"
    } > "$heartbeat" 2>/dev/null || true

    # 2. Append to ambient.jsonl.
    mkdir -p "$lock_dir" 2>/dev/null || true
    local json
    if command -v python3 >/dev/null 2>&1; then
        json=$(python3 -c "
import json, sys
counts_raw = sys.argv[5]
try:
    counts = json.loads(counts_raw)
except Exception:
    counts = {'raw': counts_raw}
print(json.dumps({
    'event': 'reaper_run',
    'kind': 'reaper_run',
    'reaper': sys.argv[1],
    'status': sys.argv[2],
    'duration_secs': int(sys.argv[3]),
    'ts': sys.argv[4],
    'counts': counts,
}))
" "$name" "$status" "$duration" "$ts" "$counts" 2>/dev/null || true)
    fi
    if [[ -z "$json" ]]; then
        # Fallback emitter (no python3). Counts is embedded raw; consumers
        # tolerate this.
        json="{\"event\":\"reaper_run\",\"kind\":\"reaper_run\",\"reaper\":\"$name\",\"status\":\"$status\",\"duration_secs\":$duration,\"ts\":\"$ts\",\"counts\":$counts}"
    fi
    printf '%s\n' "$json" >> "$ambient" 2>/dev/null || true
}

# reaper_finish STATUS COUNTS_JSON
# Convenience wrapper: computes elapsed time from REAPER_START_EPOCH and
# emits the run event + heartbeat for REAPER_NAME.
reaper_finish() {
    local status="${1:?reaper_finish needs status}"
    local counts="${2:-}"
    [[ -z "$counts" ]] && counts='{}'
    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - ${REAPER_START_EPOCH:-$now} ))
    reaper_emit_run "${REAPER_NAME:-unknown}" "$status" "$counts" "$elapsed"
}
