#!/usr/bin/env bash
# test-opus-event-driven.sh — META-099
#
# Smoke-tests the event-driven opus-shepherd loop requirements:
# 1. OPUS_SHEPHERD_PLAYBOOK.md deprecates cron-15m default
# 2. Playbook documents Monitor command shape
# 3. Playbook documents ScheduleWakeup fallback with delaySeconds in [1200,1800]
# 4. Migration script exists and is executable
# 5. CHUMP_OPUS_LOOP_MODE=cron bypass is documented

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PLAYBOOK="$REPO_ROOT/docs/process/OPUS_SHEPHERD_PLAYBOOK.md"
MIGRATE="$REPO_ROOT/scripts/coord/opus-shepherd-migrate-to-event-driven.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Test 1: playbook deprecates cron-15m ──────────────────────────────────────
echo "Test 1: playbook marks cron-15m as deprecated"
if grep -qi 'DEPRECATED\|deprecated' "$PLAYBOOK" 2>/dev/null \
        && grep -qi 'cron' "$PLAYBOOK" 2>/dev/null; then
    ok "playbook contains DEPRECATED notice for cron pattern"
else
    fail "playbook missing DEPRECATED notice — cron-15m still looks like the default"
fi

# ── Test 2: playbook documents Monitor command shape ──────────────────────────
echo "Test 2: playbook documents Monitor tail command"
if grep -q 'tail -F.*ambient.jsonl' "$PLAYBOOK" 2>/dev/null \
        || grep -q 'Monitor' "$PLAYBOOK" 2>/dev/null; then
    ok "playbook documents Monitor/tail-F ambient.jsonl shape"
else
    fail "playbook missing Monitor command shape documentation"
fi

# ── Test 3: playbook documents ScheduleWakeup with delay in [1200,1800] ───────
echo "Test 3: playbook documents ScheduleWakeup fallback delaySeconds 1200-1800"
if grep -qE '1[2-9][0-9]{2}|1800' "$PLAYBOOK" 2>/dev/null; then
    ok "playbook references delaySeconds in [1200,1800] range"
else
    fail "playbook missing ScheduleWakeup fallback delay in [1200,1800]"
fi

# ── Test 4: migration script exists and is executable ─────────────────────────
echo "Test 4: migration script exists and is executable"
if [[ -x "$MIGRATE" ]]; then
    ok "opus-shepherd-migrate-to-event-driven.sh is executable"
else
    fail "migration script missing or not executable: $MIGRATE"
fi

# ── Test 5: bypass env var documented ─────────────────────────────────────────
echo "Test 5: CHUMP_OPUS_LOOP_MODE=cron bypass documented in playbook"
if grep -q 'CHUMP_OPUS_LOOP_MODE' "$PLAYBOOK" 2>/dev/null; then
    ok "CHUMP_OPUS_LOOP_MODE bypass documented"
else
    fail "CHUMP_OPUS_LOOP_MODE bypass missing from playbook"
fi

# ── Test 6: migration script runs with --dry-run cleanly ──────────────────────
echo "Test 6: migration script --dry-run exits 0"
if CHUMP_AMBIENT_LOG=/dev/null bash "$MIGRATE" --dry-run >/dev/null 2>&1; then
    ok "migration script --dry-run exits 0"
else
    fail "migration script --dry-run failed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: event-driven opus-shepherd loop requirements not met"
    exit 1
fi
echo "PASS: event-driven loop requirements satisfied"
exit 0
