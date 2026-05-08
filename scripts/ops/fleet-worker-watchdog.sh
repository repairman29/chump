#!/usr/bin/env bash
# fleet-worker-watchdog.sh — FLEET-042: monitor worker heartbeat files
# and emit ALERT kind=fleet_worker_silent if a worker goes silent.
#
# Each worker writes /tmp/chump-fleet-worker-<idx>.heartbeat every 60s.
# Watchdog checks every 2 minutes and alerts if any heartbeat is > 5min stale.
#
# Usage:
#   scripts/ops/fleet-worker-watchdog.sh
#   REPO_ROOT=/path/to/repo scripts/ops/fleet-worker-watchdog.sh
#
# Env:
#   REPO_ROOT       (default: git root) where to emit ambient.jsonl
#   HEARTBEAT_TIMEOUT_S (default: 300) max age before alert (5min)
#   HEARTBEAT_DIR   (default: /tmp) where to check .heartbeat files

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HEARTBEAT_DIR="${HEARTBEAT_DIR:-/tmp}"
HEARTBEAT_TIMEOUT_S="${HEARTBEAT_TIMEOUT_S:-300}"

_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$_amb")" 2>/dev/null || true

now=$(date +%s)

# Find all heartbeat files and check age.
for hb in "$HEARTBEAT_DIR"/chump-fleet-worker-*.heartbeat; do
    [[ -f "$hb" ]] || continue

    # File name: /tmp/chump-fleet-worker-<idx>.heartbeat
    worker_idx=$(basename "$hb" | sed 's/chump-fleet-worker-//;s/\.heartbeat//')

    # Read heartbeat: "epoch gap_id"
    read -r hb_epoch hb_gap_id < "$hb" 2>/dev/null || {
        # Malformed file; skip.
        continue
    }

    # Check staleness.
    [[ "$hb_epoch" =~ ^[0-9]+$ ]] || continue
    age=$(( now - hb_epoch ))

    if [[ $age -gt $HEARTBEAT_TIMEOUT_S ]]; then
        # Emit ALERT to ambient.jsonl.
        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"event":"ALERT","kind":"fleet_worker_silent","ts":"%s","worker_idx":"%s","heartbeat_file":"%s","age_seconds":%d,"gap_id":"%s","hint":"worker %s has not updated heartbeat in %d seconds; likely hung or crashed"}\n' \
            "$_ts" "$worker_idx" "$hb" "$age" "$hb_gap_id" "$worker_idx" "$age" \
            >> "$_amb" 2>/dev/null || true
    fi
done
