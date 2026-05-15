#!/usr/bin/env bash
# emergency-fast-path.sh — INFRA-847
#
# Emergency read/write accessor for .chump-locks/fleet-state.json.
# Wraps all reads and writes in flock(1) to prevent torn JSON under
# concurrent access (operator + curator both touching fleet state).
#
# Usage:
#   scripts/coord/emergency-fast-path.sh read              # print fleet-state.json
#   scripts/coord/emergency-fast-path.sh write <json>      # replace fleet-state.json atomically
#   scripts/coord/emergency-fast-path.sh set-field key val # merge a top-level key
#   scripts/coord/emergency-fast-path.sh reset             # write default fleet state
#   scripts/coord/emergency-fast-path.sh status            # human-readable summary
#
# Env:
#   CHUMP_FLEET_STATE_MUTEX          0 = bypass locking (debug only)
#   CHUMP_FLEET_STATE_LOCK_TIMEOUT_S lock wait timeout (default 5)
#   CHUMP_AMBIENT_LOG                path to ambient.jsonl
#   REPO_ROOT                        override repo root detection

set -euo pipefail

# Resolve REPO_ROOT from this script's location to avoid INFRA-779
# (git rev-parse --show-toplevel returns wrong path in linked worktrees on macOS).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"
_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_lock_dir="$(dirname "$_amb")"
_state_file="$_lock_dir/fleet-state.json"
_lock_file="$_lock_dir/fleet-state.lock"
_lock_timeout="${CHUMP_FLEET_STATE_LOCK_TIMEOUT_S:-5}"
_mutex="${CHUMP_FLEET_STATE_MUTEX:-1}"

# INFRA-841: frequency-aware scheduling — emit kind=system_gap_tick on each run.
_TICK_HELPER="$REPO_ROOT/scripts/coord/system-gap-tick.sh"
if [[ -r "$_TICK_HELPER" ]]; then
  # shellcheck source=./system-gap-tick.sh
  # shellcheck disable=SC1091
  source "$_TICK_HELPER"
fi

_emit() {
    local kind="$1"; shift
    printf '{"ts":"%s","kind":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$*" \
        >> "$_amb" 2>/dev/null || true
}

_default_state() {
    printf '{"ts":"%s","fleet_size":0,"health":"unknown","workers":[]}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Run $@ under exclusive flock. On timeout: log warning, emit ambient event,
# proceed without lock (fail-open) so callers don't deadlock.
_with_lock() {
    mkdir -p "$_lock_dir"
    if [[ "${_mutex}" == "0" ]]; then
        "$@"; return
    fi
    {
        local flock_rc=0
        flock -w "$_lock_timeout" 9 || flock_rc=$?
        if [[ $flock_rc -ne 0 ]]; then
            echo "[emergency-fast-path] WARN: fleet-state.lock timeout (${_lock_timeout}s) — proceeding without lock" >&2
            _emit "fleet_state_lock_timeout" \
                '"source":"emergency-fast-path","timeout_s":'"$_lock_timeout"',"note":"INFRA-847"'
        fi
        "$@"
    } 9>"$_lock_file"
}

_read_state() {
    if [[ ! -f "$_state_file" ]]; then
        _default_state
    else
        cat "$_state_file"
    fi
}

_write_state() {
    local json="$1"
    echo "$json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null \
        || { echo "[emergency-fast-path] ERROR: invalid JSON — aborting write" >&2; return 1; }
    printf '%s\n' "$json" > "${_state_file}.tmp"
    mv "${_state_file}.tmp" "$_state_file"
}

_set_field() {
    local key="$1" val="$2"
    local current
    current="$(_with_lock _read_state)"
    echo "$current" | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
d['$key'] = '$val'
d['ts'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(d))
"
}

cmd="${1:-status}"
shift || true

# INFRA-841: heartbeat emission for `status` invocation (scheduled-task path).
# Skip on accessor sub-commands (read/write/set-field/reset) so internal
# callers from opus-curator don't double-count.
if [[ "$cmd" == "status" ]] && declare -F emit_system_gap_tick >/dev/null 2>&1; then
  emit_system_gap_tick emergency-fast-path
fi

case "$cmd" in
    read)
        _with_lock _read_state
        ;;
    write)
        json="${1:?write requires a JSON argument}"
        _with_lock _write_state "$json"
        ;;
    set-field)
        key="${1:?set-field requires key and value}"
        val="${2:?set-field requires a value}"
        new_json="$(_set_field "$key" "$val")"
        _with_lock _write_state "$new_json"
        ;;
    reset)
        _with_lock _write_state "$(_default_state)"
        echo "[emergency-fast-path] Fleet state reset to defaults." >&2
        ;;
    status)
        state="$(_with_lock _read_state)"
        echo "Fleet state (mutex:$( [[ "${_mutex}" == "0" ]] && echo "OFF" || echo "ON" )):"
        echo "$state" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {k}: {v}') for k,v in d.items()]" \
            2>/dev/null || echo "  (could not parse — raw: $state)"
        # INFRA-845: invoke wedge handler on the scheduled-cron path.
        # Best-effort — handler degrades gracefully if no wedge events present.
        _wedge_handler="$REPO_ROOT/scripts/coord/fleet-wedge-handler.sh"
        if [[ -x "$_wedge_handler" && "${CHUMP_WEDGE_HANDLER_DISABLE:-0}" != "1" ]]; then
          CHUMP_AMBIENT_LOG="$_amb" \
          CHUMP_FLEET_STATE="$_state_file" \
          REPO_ROOT="$REPO_ROOT" \
          bash "$_wedge_handler" 2>&1 | sed 's/^/[wedge-handler] /' || true
        fi
        ;;
    *)
        echo "Usage: $0 {read|write <json>|set-field <key> <val>|reset|status}" >&2
        exit 1
        ;;
esac
