#!/usr/bin/env bash
# waste-spike-detector.sh — FLEET-054
#
# Reads the last 2-hour waste tally and auto-pauses the fleet when the
# waste rate (incidents / total_events) exceeds CHUMP_WASTE_SPIKE_THRESHOLD
# (default 30%). Removes the pause when the rate falls below
# CHUMP_WASTE_RECOVERY_THRESHOLD (default 20%) for two consecutive checks.
#
# Usage:
#   ./scripts/coord/waste-spike-detector.sh          # one-shot check
#   ./scripts/coord/waste-spike-detector.sh --check  # same, explicit
#
# Env overrides:
#   CHUMP_WASTE_SPIKE_THRESHOLD   — spike threshold, integer percent (default 30)
#   CHUMP_WASTE_RECOVERY_THRESHOLD — recovery threshold, integer percent (default 20)
#   CHUMP_WASTE_WINDOW             — tally window (default 2h)
#   CHUMP_AMBIENT_LOG              — path to ambient.jsonl (default .chump-locks/ambient.jsonl)
#   CHUMP_FLEET_PAUSE_FILE         — path to fleet-paused flag file (default .chump/fleet-paused)
#   CHUMP_WASTE_CONSEC_FILE        — path to consecutive-below-threshold counter (default /tmp/chump-waste-recovery-count)
#
# Emits to ambient.jsonl:
#   kind=waste_spike_detected    — when rate exceeds spike threshold
#   kind=fleet_resumed           — when rate falls below recovery threshold ×2 consecutive
#
# Install via launchd (runs every 15 min):
#   ./scripts/setup/install-waste-spike-detector-launchd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Common-dir resolution for linked worktrees.
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    REPO_ROOT="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir | xargs dirname 2>/dev/null || echo "$REPO_ROOT")"
fi

SPIKE_THRESHOLD="${CHUMP_WASTE_SPIKE_THRESHOLD:-30}"
RECOVERY_THRESHOLD="${CHUMP_WASTE_RECOVERY_THRESHOLD:-20}"
WINDOW="${CHUMP_WASTE_WINDOW:-2h}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
PAUSE_FILE="${CHUMP_FLEET_PAUSE_FILE:-$REPO_ROOT/.chump/fleet-paused}"
CONSEC_FILE="${CHUMP_WASTE_CONSEC_FILE:-/tmp/chump-waste-recovery-count}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1"; shift
    local extra="${1:-}"
    local ts; ts="$(_ts)"
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "${extra:+,$extra}" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Read waste tally ───────────────────────────────────────────────────────────
tally_json=$(CHUMP_AMBIENT_LOG="$AMBIENT" \
    chump waste-tally --since "$WINDOW" --json 2>/dev/null || echo '{}')

total_events=$(printf '%s' "$tally_json" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('total_events',0))" 2>/dev/null || echo 0)
total_incidents=$(printf '%s' "$tally_json" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('total_incidents',0))" 2>/dev/null || echo 0)

# Avoid division by zero; rate is 0 when no events yet.
if [[ "$total_events" -eq 0 ]]; then
    waste_rate=0
else
    # Integer percent: incidents/events × 100 (rounded down).
    waste_rate=$(( total_incidents * 100 / total_events ))
fi

echo "[waste-spike-detector] window=$WINDOW events=$total_events incidents=$total_incidents rate=${waste_rate}%"

# ── Spike detection ────────────────────────────────────────────────────────────
if [[ $waste_rate -gt $SPIKE_THRESHOLD ]]; then
    echo "[waste-spike-detector] SPIKE: rate ${waste_rate}% > threshold ${SPIKE_THRESHOLD}% — pausing fleet"
    mkdir -p "$(dirname "$PAUSE_FILE")"
    printf '%s\n' "$(_ts)" > "$PAUSE_FILE"
    _emit "waste_spike_detected" \
        '"rate":'"$waste_rate"',"threshold":'"$SPIKE_THRESHOLD"',"window":"'"$WINDOW"'","total_events":'"$total_events"',"total_incidents":'"$total_incidents"
    # Reset consecutive-recovery counter on any spike.
    echo 0 > "$CONSEC_FILE" 2>/dev/null || true
    exit 0
fi

# ── Recovery check ────────────────────────────────────────────────────────────
if [[ -f "$PAUSE_FILE" ]]; then
    if [[ $waste_rate -lt $RECOVERY_THRESHOLD ]]; then
        # Increment consecutive-below-threshold counter.
        consec=0
        [[ -f "$CONSEC_FILE" ]] && consec=$(cat "$CONSEC_FILE" 2>/dev/null || echo 0)
        consec=$(( consec + 1 ))
        echo $consec > "$CONSEC_FILE"
        echo "[waste-spike-detector] rate ${waste_rate}% < recovery threshold ${RECOVERY_THRESHOLD}% (check $consec/2)"
        if [[ $consec -ge 2 ]]; then
            rm -f "$PAUSE_FILE"
            echo 0 > "$CONSEC_FILE"
            echo "[waste-spike-detector] RECOVERED: fleet-paused removed after 2 consecutive checks below ${RECOVERY_THRESHOLD}%"
            _emit "fleet_resumed" \
                '"rate":'"$waste_rate"',"recovery_threshold":'"$RECOVERY_THRESHOLD"',"window":"'"$WINDOW"
        fi
    else
        # Still above recovery threshold — reset consecutive counter.
        echo 0 > "$CONSEC_FILE" 2>/dev/null || true
        echo "[waste-spike-detector] rate ${waste_rate}% still above recovery threshold ${RECOVERY_THRESHOLD}% — fleet remains paused"
    fi
else
    # No pause file — healthy, reset recovery counter.
    echo 0 > "$CONSEC_FILE" 2>/dev/null || true
    echo "[waste-spike-detector] rate ${waste_rate}% ≤ spike threshold ${SPIKE_THRESHOLD}% — fleet healthy"
fi

exit 0
