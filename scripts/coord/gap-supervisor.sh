#!/usr/bin/env bash
# gap-supervisor.sh — RESILIENT-058 (A2A L6a per-gap supervision tree)
#
# Tracks restart attempts per gap-id in a rolling window. When a gap exceeds
# CHUMP_GAP_SUPERVISOR_MAX_RESTARTS restarts within CHUMP_GAP_SUPERVISOR_WINDOW_S
# seconds, the gap is escalated: set status=blocked + emit kind=gap_supervisor_escalated.
#
# MOTIVATING INCIDENT (2026-06-03 ~07:35Z): 12 audit runs were IN_PROGRESS for
# 25+ min on 4 self-hosted runners with no fleet supervisor to catch the retry-storm.
# The fleet had to be manually unblocked by the operator. This script is the per-gap
# layer of the Erlang/OTP-style supervision tree described in:
#   docs/design/A2A_MASTER_PLAN_2026-06-03.md §1.L6 and §M2
#
# Usage:
#   gap-supervisor.sh record <gap-id>
#       Record one restart for gap-id. Returns rc=0 if restart is allowed,
#       rc=1 if escalation was triggered (gap is now blocked).
#
#   gap-supervisor.sh tick
#       Daemon-mode: emit heartbeat, check all recent escalation windows.
#       Safe to call from launchd every 60s (com.chump.gap-supervisor.plist).
#
#   gap-supervisor.sh status <gap-id>
#       Print restart count in the rolling window for a gap. Exits 0.
#
#   gap-supervisor.sh purge
#       Remove state file (test/reset use only).
#
# Thresholds (env-tunable):
#   CHUMP_GAP_SUPERVISOR_MAX_RESTARTS  default 3   — max restarts before escalate
#   CHUMP_GAP_SUPERVISOR_WINDOW_S      default 300  — rolling window (seconds)
#
# State file:
#   .chump-locks/.gap-supervisor-state.jsonl — append-only event log
#
# Bypass: none (by design). Thresholds are env-tunable for test harnesses.
#
# Rust-First-Bypass: reads/writes .chump-locks state + calls chump gap update;
#   per META-064 criteria, this mutates canonical state and could be Rust.
#   Filed RESILIENT-059 for Rust port. First-cut in shell for speed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# ── Thresholds ─────────────────────────────────────────────────────────────────
MAX_RESTARTS="${CHUMP_GAP_SUPERVISOR_MAX_RESTARTS:-3}"
WINDOW_S="${CHUMP_GAP_SUPERVISOR_WINDOW_S:-300}"

# ── Paths ──────────────────────────────────────────────────────────────────────
STATE_FILE="${CHUMP_GAP_SUPERVISOR_STATE:-$REPO_ROOT/.chump-locks/.gap-supervisor-state.jsonl}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
AMBIENT_EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
CHUMP_BIN="${CHUMP_BIN:-chump}"

# ── Helpers ────────────────────────────────────────────────────────────────────

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

emit_event() {
    local kind="$1"; shift
    local ts; ts="$(now_ts)"
    # Try ambient-emit.sh first (provides flock + harness attribution).
    # Fall back to direct printf when the script is missing or fails (e.g. flock
    # not available on macOS without util-linux, or running in test isolation).
    if [[ -x "$AMBIENT_EMIT" ]] && bash "$AMBIENT_EMIT" "$kind" ts="$ts" "$@" 2>/dev/null; then
        return 0
    fi
    # Fallback: direct printf without flock (best-effort, still atomic for
    # single-line appends on most POSIX filesystems).
    local kv_json="{\"ts\":\"$ts\",\"kind\":\"$kind\""
    for pair in "$@"; do
        local k="${pair%%=*}"
        local v="${pair#*=}"
        kv_json="${kv_json},\"${k}\":\"${v}\""
    done
    kv_json="${kv_json},\"source\":\"gap-supervisor.sh\"}"
    printf '%s\n' "$kv_json" >> "$AMBIENT_LOG" 2>/dev/null || true
}

append_state() {
    # Append one event to STATE_FILE in a simple atomic manner (line-at-a-time append).
    local line="$1"
    printf '%s\n' "$line" >> "$STATE_FILE" 2>/dev/null || true
}

# Count restarts for a given gap_id in the rolling window.
# Prints the count to stdout.
count_restarts_in_window() {
    local gap_id="$1"
    local cutoff; cutoff=$(( $(now_epoch) - WINDOW_S ))
    [[ -f "$STATE_FILE" ]] || { echo 0; return; }

    python3 - "$STATE_FILE" "$gap_id" "$cutoff" <<'PYEOF'
import sys, json
state_file, gap_id, cutoff_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
count = 0
try:
    with open(state_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("gap_id") != gap_id:
                continue
            if ev.get("action") != "restart":
                continue
            # Parse ts — expect ISO8601 UTC
            import datetime
            ts_str = ev.get("ts", "")
            try:
                ts_str_clean = ts_str.rstrip("Z")
                dt = datetime.datetime.fromisoformat(ts_str_clean)
                epoch = int(dt.timestamp())
            except Exception:
                continue
            if epoch >= cutoff_s:
                count += 1
except FileNotFoundError:
    pass
print(count)
PYEOF
}

# ── Command: record ────────────────────────────────────────────────────────────
cmd_record() {
    local gap_id="${1:-}"
    if [[ -z "$gap_id" ]]; then
        echo "[gap-supervisor] ERROR: record requires a gap-id argument" >&2
        exit 2
    fi

    local ts; ts="$(now_ts)"
    local epoch; epoch="$(now_epoch)"

    # Append restart event to state.
    local restart_event
    restart_event="$(python3 -c "import json; print(json.dumps({'ts':'$ts','gap_id':'$gap_id','action':'restart','source':'gap-supervisor'}))")"
    append_state "$restart_event"

    # Count restarts in window after recording.
    local count; count="$(count_restarts_in_window "$gap_id")"

    # Emit heartbeat per tick.
    emit_event "gap_supervisor_heartbeat" \
        gap_id="$gap_id" \
        restart_count="$count" \
        window_s="$WINDOW_S" \
        max_restarts="$MAX_RESTARTS" \
        source="gap-supervisor.sh"

    if [[ "$count" -gt "$MAX_RESTARTS" ]]; then
        # Threshold exceeded — escalate.
        local escalate_event
        escalate_event="$(python3 -c "import json; print(json.dumps({'ts':'$ts','gap_id':'$gap_id','action':'escalate','attempt_count':$count,'source':'gap-supervisor'}))")"
        append_state "$escalate_event"

        # Block the gap via chump CLI.
        if command -v "$CHUMP_BIN" &>/dev/null; then
            "$CHUMP_BIN" gap update "$gap_id" status blocked 2>/dev/null || true
        fi

        # Emit gap_supervisor_escalated to ambient stream.
        emit_event "gap_supervisor_escalated" \
            gap_id="$gap_id" \
            restart_count="$count" \
            window_s="$WINDOW_S" \
            reason="restart_storm: ${count} restarts within ${WINDOW_S}s exceeds threshold ${MAX_RESTARTS}" \
            source="gap-supervisor.sh"

        echo "[gap-supervisor] ESCALATED: $gap_id — $count restarts in ${WINDOW_S}s (threshold: $MAX_RESTARTS). Gap status set to blocked." >&2
        return 1
    fi

    echo "[gap-supervisor] OK: $gap_id — $count/$MAX_RESTARTS restarts in rolling ${WINDOW_S}s window." >&2
    return 0
}

# ── Command: tick ──────────────────────────────────────────────────────────────
cmd_tick() {
    local ts; ts="$(now_ts)"

    # Emit heartbeat.
    emit_event "gap_supervisor_heartbeat" \
        mode="tick" \
        state_file="$STATE_FILE" \
        source="gap-supervisor.sh"

    echo "[gap-supervisor] heartbeat tick at $ts — state: $STATE_FILE" >&2
    return 0
}

# ── Command: status ────────────────────────────────────────────────────────────
cmd_status() {
    local gap_id="${1:-}"
    if [[ -z "$gap_id" ]]; then
        echo "[gap-supervisor] ERROR: status requires a gap-id argument" >&2
        exit 2
    fi
    local count; count="$(count_restarts_in_window "$gap_id")"
    echo "$gap_id: $count/$MAX_RESTARTS restarts in rolling ${WINDOW_S}s window"
    return 0
}

# ── Command: purge ─────────────────────────────────────────────────────────────
cmd_purge() {
    if [[ -f "$STATE_FILE" ]]; then
        rm -f "$STATE_FILE"
        echo "[gap-supervisor] state file purged: $STATE_FILE" >&2
    else
        echo "[gap-supervisor] state file not found: $STATE_FILE" >&2
    fi
    return 0
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
CMD="${1:-tick}"
shift || true

case "$CMD" in
    record)  cmd_record "$@" ;;
    tick)    cmd_tick "$@" ;;
    status)  cmd_status "$@" ;;
    purge)   cmd_purge "$@" ;;
    -h|--help)
        sed -n '3,50p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "[gap-supervisor] ERROR: unknown command '$CMD'. Use: record <gap-id> | tick | status <gap-id> | purge" >&2
        exit 2
        ;;
esac
