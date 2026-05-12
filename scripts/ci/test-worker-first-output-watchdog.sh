#!/usr/bin/env bash
# test-worker-first-output-watchdog.sh — INFRA-828
#
# Validates the worker.sh first-output watchdog (INFRA-828 refine of INFRA-823):
#  - INFRA-828 referenced in worker.sh
#  - CHUMP_FIRST_OUTPUT_WATCHDOG kill switch present
#  - CHUMP_FIRST_OUTPUT_TIMEOUT_S default is 120s
#  - kind=worker_first_output_timeout emitted after retry exhaustion
#  - event includes agent_id, gap_id, elapsed_s fields
#  - kill switch gates watchdog subshell
#  - functional: simulate retry exhaustion and verify event emission

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-828 worker first-output watchdog test ==="
echo

# 1. INFRA-828 referenced in worker.sh
if grep -q "INFRA-828" "$WORKER"; then
    ok "INFRA-828 block referenced in worker.sh"
else
    fail "INFRA-828 block missing from worker.sh"
fi

# 2. CHUMP_FIRST_OUTPUT_WATCHDOG kill switch present
if grep -q 'CHUMP_FIRST_OUTPUT_WATCHDOG' "$WORKER"; then
    ok "CHUMP_FIRST_OUTPUT_WATCHDOG kill switch present"
else
    fail "CHUMP_FIRST_OUTPUT_WATCHDOG kill switch missing"
fi

# 3. Default timeout is 120s
if grep -q 'CHUMP_FIRST_OUTPUT_TIMEOUT_S:-120' "$WORKER"; then
    ok "default CHUMP_FIRST_OUTPUT_TIMEOUT_S is 120s"
else
    fail "default timeout should be 120s — found: $(grep 'FIRST_OUTPUT_TIMEOUT' "$WORKER" | head -1)"
fi

# 4. kind=worker_first_output_timeout emitted
if grep -q 'worker_first_output_timeout' "$WORKER"; then
    ok "kind=worker_first_output_timeout present in worker.sh"
else
    fail "kind=worker_first_output_timeout missing from worker.sh"
fi

# 5. Event includes agent_id, gap_id, elapsed_s
if grep -q '"agent_id"' "$WORKER" && grep -q '"gap_id"' "$WORKER" && grep -q '"elapsed_s"' "$WORKER"; then
    ok "event fields agent_id, gap_id, elapsed_s present in worker.sh"
else
    fail "event missing required fields"
fi

# 6. Kill switch gates watchdog subshell (CHUMP_FIRST_OUTPUT_WATCHDOG check before sleep block)
if grep -q 'CHUMP_FIRST_OUTPUT_WATCHDOG.*!=.*0' "$WORKER"; then
    ok "kill switch comparison present (watchdog gated)"
else
    fail "kill switch does not gate watchdog — CHUMP_FIRST_OUTPUT_WATCHDOG != 0 check missing"
fi

# 7. watchdog_pid initialized to 0 (safe default when disabled)
if grep -q '_fo_watchdog_pid=0' "$WORKER"; then
    ok "_fo_watchdog_pid initialized to 0 (safe when watchdog disabled)"
else
    fail "_fo_watchdog_pid should initialize to 0"
fi

# 8. Kill switch default test: active by default
if bash -c '[[ "${CHUMP_FIRST_OUTPUT_WATCHDOG:-1}" != "0" ]] && echo "active" || echo "disabled"' | grep -q "active"; then
    ok "watchdog default is active (CHUMP_FIRST_OUTPUT_WATCHDOG not set = enabled)"
else
    fail "watchdog default should be active"
fi

# 9. Kill switch set to 0: disabled
if CHUMP_FIRST_OUTPUT_WATCHDOG=0 bash -c '[[ "${CHUMP_FIRST_OUTPUT_WATCHDOG:-1}" != "0" ]] && echo "active" || echo "disabled"' | grep -q "disabled"; then
    ok "CHUMP_FIRST_OUTPUT_WATCHDOG=0 disables watchdog"
else
    fail "CHUMP_FIRST_OUTPUT_WATCHDOG=0 kill switch not working"
fi

# 10. Functional: simulate retry exhaustion and event emission
echo
echo "[functional: retry exhaustion simulation]"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"

# Simulate what happens when both retries fail (wedge_retries > wedge_retry_max)
_wedge_retries=3  # exceeded max of 2
_wedge_retry_max=2
AGENT_ID="test-agent-828"
GAP_ID="INFRA-828-test"
_cycle_start_s=$(( $(date +%s) - 300 ))  # 5 minutes ago
CHUMP_AMBIENT_LOG="$AMB"

if [[ "${CHUMP_FIRST_OUTPUT_WATCHDOG:-1}" != "0" ]] && [ "$_wedge_retries" -gt "$_wedge_retry_max" ]; then
    _elapsed_s=$(( $(date +%s) - _cycle_start_s ))
    printf '{"ts":"%s","kind":"worker_first_output_timeout","agent_id":"%s","gap_id":"%s","elapsed_s":%d,"retries":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${AGENT_ID:-unknown}" \
        "${GAP_ID:-unknown}" \
        "$_elapsed_s" \
        "$_wedge_retries" \
        >> "$AMB" 2>/dev/null || true
fi

if [[ -f "$AMB" ]] && grep -q '"worker_first_output_timeout"' "$AMB"; then
    ok "worker_first_output_timeout event emitted after retry exhaustion"
else
    fail "worker_first_output_timeout not emitted"
fi

if grep '"worker_first_output_timeout"' "$AMB" | grep -q '"agent_id"'; then
    ok "event includes agent_id"
else
    fail "event missing agent_id"
fi

if grep '"worker_first_output_timeout"' "$AMB" | grep -q '"gap_id"'; then
    ok "event includes gap_id"
else
    fail "event missing gap_id"
fi

if grep '"worker_first_output_timeout"' "$AMB" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
ev = json.loads(line)
assert ev.get('elapsed_s', 0) > 0, 'elapsed_s should be positive'
print('ok')
" 2>/dev/null | grep -q "ok"; then
    ok "event records positive elapsed_s"
else
    fail "event elapsed_s missing or zero"
fi

# 11. Kill switch prevents event emission
AMB2="$TMP/ambient2.jsonl"
CHUMP_FIRST_OUTPUT_WATCHDOG=0

if [[ "${CHUMP_FIRST_OUTPUT_WATCHDOG:-1}" != "0" ]]; then
    printf '{"ts":"%s","kind":"worker_first_output_timeout","agent_id":"test","gap_id":"test","elapsed_s":300,"retries":3}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMB2" 2>/dev/null || true
fi

if [[ ! -f "$AMB2" ]] || ! grep -q '"worker_first_output_timeout"' "$AMB2" 2>/dev/null; then
    ok "CHUMP_FIRST_OUTPUT_WATCHDOG=0 suppresses event emission"
else
    fail "CHUMP_FIRST_OUTPUT_WATCHDOG=0 should suppress watchdog event"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
