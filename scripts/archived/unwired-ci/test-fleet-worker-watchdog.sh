#!/usr/bin/env bash
# test-fleet-worker-watchdog.sh — FLEET-042: verify worker heartbeat + watchdog
#
# Test plan:
#   1. Create a stale heartbeat file (> 5min old)
#   2. Run the watchdog script
#   3. Assert ALERT kind=fleet_worker_silent in ambient.jsonl
#   4. Clean up

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HEARTBEAT_DIR="${HEARTBEAT_DIR:-/tmp}"
TEST_DIR="$(mktemp -d -t chump-watchdog-test.XXXXXX)"
trap "rm -rf '$TEST_DIR'" EXIT

# Set up test ambient.jsonl
CHUMP_AMBIENT_LOG="$TEST_DIR/ambient.jsonl"
export CHUMP_AMBIENT_LOG
: > "$CHUMP_AMBIENT_LOG"

# Create a stale heartbeat file (> 5min old).
# Heartbeat format: "epoch gap_id"
stale_epoch=$(( $(date +%s) - 360 ))  # 6 minutes ago
test_heartbeat="$HEARTBEAT_DIR/chump-fleet-worker-test-1.heartbeat"
printf '%d %s\n' "$stale_epoch" "FLEET-042" > "$test_heartbeat"
trap "rm -f '$test_heartbeat'" EXIT

echo "[test] created stale heartbeat: $test_heartbeat (age: 360s)"
echo "[test] running watchdog..."

# Run the watchdog.
REPO_ROOT="$REPO_ROOT" HEARTBEAT_DIR="$HEARTBEAT_DIR" \
    "$REPO_ROOT/scripts/ops/fleet-worker-watchdog.sh" || {
    echo "ERROR: watchdog script failed" >&2
    exit 1
}

# Check that ALERT was emitted.
if grep -q '"kind":"fleet_worker_silent"' "$CHUMP_AMBIENT_LOG"; then
    echo "[test] ✓ ALERT kind=fleet_worker_silent detected in ambient.jsonl"
    echo "[test] full alert:"
    grep '"kind":"fleet_worker_silent"' "$CHUMP_AMBIENT_LOG"
else
    echo "ERROR: ALERT kind=fleet_worker_silent NOT found in ambient.jsonl" >&2
    echo "[test] ambient.jsonl contents:"
    cat "$CHUMP_AMBIENT_LOG" >&2
    exit 1
fi

# Verify the alert includes expected fields.
alert_line=$(grep '"kind":"fleet_worker_silent"' "$CHUMP_AMBIENT_LOG")
if echo "$alert_line" | grep -q '"age_seconds":'; then
    echo "[test] ✓ age_seconds field present"
else
    echo "ERROR: age_seconds field missing in alert" >&2
    exit 1
fi

if echo "$alert_line" | grep -q '"worker_idx":"test-1"'; then
    echo "[test] ✓ worker_idx field correct"
else
    echo "ERROR: worker_idx field incorrect in alert" >&2
    exit 1
fi

echo "[test] ✓ all checks passed"
