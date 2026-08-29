#!/usr/bin/env bash
# test-stale-bot-merge-health.sh — INFRA-1531 smoke test for the stale
# bot-merge-*.health reaper wired into scripts/dev/chump-ambient-glance.sh.
#
# Writes a fake health file for a dead pid (99999) and asserts the reaper
# removes it and emits kind=bot_merge_health_reaped to ambient.jsonl.
# Also verifies a health file for a LIVE pid ($$) is left alone.
#
# Run from repo root: bash scripts/ci/test-stale-bot-merge-health.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

mkdir -p "$SANDBOX/.chump-locks"

# ── Case 1: dead pid=99999 health file is reaped ────────────────────────────
DEAD_HEALTH="$SANDBOX/.chump-locks/bot-merge-99999.health"
printf '{"pid":99999,"started_at":"2026-05-15T20:22:00Z","current_step":"ship","last_heartbeat_at":"2026-05-15T20:22:00Z","gap_ids":"INFRA-1531"}\n' \
    > "$DEAD_HEALTH"

CHUMP_LOCK_DIR="$SANDBOX/.chump-locks" \
CHUMP_AMBIENT_GLANCE_REAP=1 \
    bash scripts/dev/chump-ambient-glance.sh --quiet >/dev/null 2>&1 || true

if [[ ! -e "$DEAD_HEALTH" ]]; then
    pass "dead-pid health file removed"
else
    fail "dead-pid health file still present"
fi

if grep -q '"kind":"bot_merge_health_reaped"' "$SANDBOX/.chump-locks/ambient.jsonl" 2>/dev/null \
    && grep -q '"pid":99999' "$SANDBOX/.chump-locks/ambient.jsonl" 2>/dev/null; then
    pass "kind=bot_merge_health_reaped emitted with pid=99999"
else
    fail "kind=bot_merge_health_reaped not emitted (or missing pid)"
fi

# ── Case 2: live pid health file is left alone ──────────────────────────────
LIVE_PID=$$
LIVE_HEALTH="$SANDBOX/.chump-locks/bot-merge-${LIVE_PID}.health"
printf '{"pid":%d,"started_at":"2026-08-28T00:00:00Z","current_step":"ship","last_heartbeat_at":"2026-08-28T00:00:00Z","gap_ids":""}\n' \
    "$LIVE_PID" > "$LIVE_HEALTH"

CHUMP_LOCK_DIR="$SANDBOX/.chump-locks" \
CHUMP_AMBIENT_GLANCE_REAP=1 \
    bash scripts/dev/chump-ambient-glance.sh --quiet >/dev/null 2>&1 || true

if [[ -e "$LIVE_HEALTH" ]]; then
    pass "live-pid health file left in place"
else
    fail "live-pid health file was incorrectly removed"
fi

echo ""
echo "=== test-stale-bot-merge-health.sh: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
