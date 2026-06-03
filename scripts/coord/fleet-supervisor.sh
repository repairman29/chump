#!/usr/bin/env bash
# fleet-supervisor.sh — RESILIENT-058 (A2A L6a fleet-aggregate supervision tree)
#
# Aggregates per-gap escalation events from ambient.jsonl. When the count of
# kind=gap_supervisor_escalated events in the rolling window exceeds
# CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS, new gap pickup is paused by creating
# a sentinel file. Recovery requires fleet-doctor-strict.sh to pass.
#
# MOTIVATING INCIDENT (2026-06-03 ~07:35Z): 12 CI audit runs wedged for 25+
# min. fleet supervisor at this layer would have paused pickup after the 2nd
# gap-supervisor escalation, preventing further retry-storm accumulation while
# surfacing the problem to operator-recall.
# See: docs/design/A2A_MASTER_PLAN_2026-06-03.md §1.L6, §M2
#
# Usage:
#   fleet-supervisor.sh tick
#       Count recent escalations. If > threshold: create pause sentinel.
#       If sentinel exists: attempt recovery via fleet-doctor-strict.sh.
#       Emits heartbeat. Safe to call from launchd every 300s.
#
#   fleet-supervisor.sh resume-attempt
#       Manually trigger a recovery attempt (run fleet-doctor-strict.sh).
#       If it passes: remove sentinel + emit kind=fleet_pickup_resumed.
#       If it fails: keep sentinel + emit kind=fleet_doctor_strict_failed.
#
#   fleet-supervisor.sh status
#       Print current pause state + recent escalation count.
#
# Thresholds (env-tunable):
#   CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS  default 2   — max before pause
#   CHUMP_FLEET_SUPERVISOR_WINDOW_S         default 600  — rolling window (seconds)
#
# Sentinel file:
#   .chump-locks/.fleet-pickup-paused — JSON: {ts, escalation_count, gap_ids}
#   Existence of this file pauses new gap pickup in chump claim.
#
# Recovery: fleet-doctor-strict.sh rc=0 removes sentinel + emits fleet_pickup_resumed.
#
# Bypass: none (by design). Thresholds are env-tunable for test harnesses.
#
# Rust-First-Bypass: reads ambient.jsonl + manages sentinel file; state mutation
#   qualifies for Rust-first (META-064). Filed RESILIENT-059 for Rust port.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# ── Thresholds ─────────────────────────────────────────────────────────────────
MAX_ESCALATIONS="${CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS:-2}"
WINDOW_S="${CHUMP_FLEET_SUPERVISOR_WINDOW_S:-600}"

# ── Paths ──────────────────────────────────────────────────────────────────────
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
SENTINEL_FILE="${CHUMP_FLEET_PICKUP_SENTINEL:-$REPO_ROOT/.chump-locks/.fleet-pickup-paused}"
FLEET_DOCTOR="${CHUMP_FLEET_DOCTOR_SCRIPT:-$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh}"
AMBIENT_EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"

# ── Helpers ────────────────────────────────────────────────────────────────────

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_event() {
    local kind="$1"; shift
    local ts; ts="$(now_ts)"
    # Try ambient-emit.sh first (provides flock + harness attribution).
    # Fall back to direct printf when the script is missing or fails (e.g. flock
    # not available on macOS without util-linux, or running in test isolation).
    if [[ -x "$AMBIENT_EMIT" ]] && bash "$AMBIENT_EMIT" "$kind" ts="$ts" "$@" 2>/dev/null; then
        return 0
    fi
    # Fallback: direct printf without flock (best-effort).
    local kv_json="{\"ts\":\"$ts\",\"kind\":\"$kind\""
    for pair in "$@"; do
        local k="${pair%%=*}"
        local v="${pair#*=}"
        kv_json="${kv_json},\"${k}\":\"${v}\""
    done
    kv_json="${kv_json},\"source\":\"fleet-supervisor.sh\"}"
    printf '%s\n' "$kv_json" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# Count gap_supervisor_escalated events in the rolling window.
# Prints count and JSON list of gap_ids to stdout (two lines).
count_recent_escalations() {
    local cutoff; cutoff=$(( $(date -u +%s) - WINDOW_S ))
    [[ -f "$AMBIENT_LOG" ]] || { echo "0"; echo "[]"; return; }

    python3 - "$AMBIENT_LOG" "$cutoff" <<'PYEOF'
import sys, json, datetime

ambient_file = sys.argv[1]
cutoff_s = int(sys.argv[2])

count = 0
gap_ids = []

try:
    with open(ambient_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("kind") != "gap_supervisor_escalated":
                continue
            ts_str = ev.get("ts", "")
            try:
                ts_clean = ts_str.rstrip("Z")
                dt = datetime.datetime.fromisoformat(ts_clean)
                epoch = int(dt.timestamp())
            except Exception:
                continue
            if epoch >= cutoff_s:
                count += 1
                gid = ev.get("gap_id", "unknown")
                if gid not in gap_ids:
                    gap_ids.append(gid)
except FileNotFoundError:
    pass

print(count)
print(json.dumps(gap_ids))
PYEOF
}

is_paused() {
    [[ -f "$SENTINEL_FILE" ]]
}

pause_pickup() {
    local escalation_count="$1"
    local gap_ids_json="$2"
    local ts; ts="$(now_ts)"

    python3 -c "
import json
sentinel = {
    'ts': '$ts',
    'escalation_count': $escalation_count,
    'gap_ids': $gap_ids_json,
    'reason': 'fleet_supervisor: ${escalation_count} gap_supervisor_escalated events in ${WINDOW_S}s (threshold: ${MAX_ESCALATIONS})',
    'recovery': 'run: bash scripts/coord/fleet-supervisor.sh resume-attempt'
}
print(json.dumps(sentinel, indent=2))
" > "$SENTINEL_FILE" 2>/dev/null || true

    emit_event "fleet_supervisor_pickup_paused" \
        escalation_count="$escalation_count" \
        window_s="$WINDOW_S" \
        gap_ids="$gap_ids_json" \
        sentinel_file="$SENTINEL_FILE" \
        source="fleet-supervisor.sh"

    echo "[fleet-supervisor] PAUSED: new gap pickup suspended. $escalation_count escalations in ${WINDOW_S}s window (threshold: $MAX_ESCALATIONS)." >&2
    echo "[fleet-supervisor] Gap IDs: $gap_ids_json" >&2
    echo "[fleet-supervisor] Recovery: bash scripts/coord/fleet-supervisor.sh resume-attempt" >&2
}

attempt_recovery() {
    local ts; ts="$(now_ts)"
    echo "[fleet-supervisor] Running fleet-doctor-strict.sh for recovery check..." >&2

    local doctor_rc=0
    local doctor_output
    doctor_output="$(bash "$FLEET_DOCTOR" --json 2>&1)" || doctor_rc=$?

    if [[ "$doctor_rc" -eq 0 ]]; then
        # Fleet is healthy — remove sentinel and resume.
        rm -f "$SENTINEL_FILE"
        emit_event "fleet_pickup_resumed" \
            recovery_method="fleet_doctor_strict" \
            source="fleet-supervisor.sh"
        echo "[fleet-supervisor] RESUMED: fleet-doctor-strict passed — pickup sentinel removed." >&2
        return 0
    else
        # Fleet still unhealthy — extract failing check names.
        local failing_checks
        failing_checks="$(echo "$doctor_output" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    fails = [c['name'] for c in d.get('checks', []) if c.get('status') == 'fail']
    print(','.join(fails))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"

        emit_event "fleet_doctor_strict_failed" \
            failing_checks="$failing_checks" \
            doctor_rc="$doctor_rc" \
            sentinel_kept="true" \
            source="fleet-supervisor.sh"

        echo "[fleet-supervisor] STILL PAUSED: fleet-doctor-strict failed (rc=$doctor_rc). Failing: $failing_checks" >&2
        echo "[fleet-supervisor] Fix the health issues above, then retry: bash scripts/coord/fleet-supervisor.sh resume-attempt" >&2
        return 1
    fi
}

# ── Command: tick ──────────────────────────────────────────────────────────────
cmd_tick() {
    local ts; ts="$(now_ts)"

    # Emit heartbeat first.
    emit_event "fleet_supervisor_heartbeat" \
        mode="tick" \
        window_s="$WINDOW_S" \
        max_escalations="$MAX_ESCALATIONS" \
        paused="$(is_paused && echo true || echo false)" \
        source="fleet-supervisor.sh"

    if is_paused; then
        # Already paused — attempt recovery on each tick.
        echo "[fleet-supervisor] Sentinel active — attempting recovery check." >&2
        attempt_recovery || true
        return 0
    fi

    # Not currently paused — count recent escalations.
    local count_output; count_output="$(count_recent_escalations)"
    local escalation_count; escalation_count="$(echo "$count_output" | head -1)"
    local gap_ids_json; gap_ids_json="$(echo "$count_output" | tail -1)"

    echo "[fleet-supervisor] $escalation_count gap_supervisor_escalated in ${WINDOW_S}s window (threshold: $MAX_ESCALATIONS)" >&2

    if [[ "$escalation_count" -ge "$MAX_ESCALATIONS" ]]; then
        pause_pickup "$escalation_count" "$gap_ids_json"
    fi

    return 0
}

# ── Command: resume-attempt ────────────────────────────────────────────────────
cmd_resume_attempt() {
    if ! is_paused; then
        echo "[fleet-supervisor] Not currently paused. Nothing to resume." >&2
        return 0
    fi
    attempt_recovery
}

# ── Command: status ────────────────────────────────────────────────────────────
cmd_status() {
    echo "=== fleet-supervisor status ==="
    if is_paused; then
        echo "  Pickup: PAUSED (sentinel: $SENTINEL_FILE)"
        python3 -c "
import json
try:
    with open('$SENTINEL_FILE') as f:
        d = json.load(f)
    print('  Paused at:', d.get('ts', '?'))
    print('  Escalation count:', d.get('escalation_count', '?'))
    print('  Gap IDs:', d.get('gap_ids', []))
    print('  Recovery:', d.get('recovery', '?'))
except Exception as e:
    print('  (could not read sentinel:', e, ')')
" 2>/dev/null || true
    else
        echo "  Pickup: ACTIVE (not paused)"
    fi

    local count_output; count_output="$(count_recent_escalations)"
    local escalation_count; escalation_count="$(echo "$count_output" | head -1)"
    local gap_ids_json; gap_ids_json="$(echo "$count_output" | tail -1)"
    echo "  Recent escalations (${WINDOW_S}s window): $escalation_count (threshold: $MAX_ESCALATIONS)"
    echo "  Escalated gap IDs: $gap_ids_json"
    return 0
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
CMD="${1:-tick}"
shift || true

case "$CMD" in
    tick)           cmd_tick "$@" ;;
    resume-attempt) cmd_resume_attempt "$@" ;;
    status)         cmd_status "$@" ;;
    -h|--help)
        sed -n '3,55p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "[fleet-supervisor] ERROR: unknown command '$CMD'. Use: tick | resume-attempt | status" >&2
        exit 2
        ;;
esac
