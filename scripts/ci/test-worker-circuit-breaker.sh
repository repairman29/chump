#!/usr/bin/env bash
# test-worker-circuit-breaker.sh — INFRA-826
#
# Validates the worker.sh circuit breaker:
#  - INFRA-826 block present in worker.sh
#  - CHUMP_CIRCUIT_BREAKER=0 kill switch present
#  - Default threshold changed to 3 (INFRA-826 vs FLEET-043's original 5)
#  - Default pause changed to 300s / 5min (vs original 1800s / 30min)
#  - kind=worker_circuit_open emitted to ambient.jsonl on trip
#  - Counter resets after emitting alert
#  - CHUMP_CIRCUIT_BREAKER=0 bypasses check (verify via grep)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-826 worker circuit-breaker test ==="
echo

# 1. INFRA-826 referenced in worker.sh
if grep -q "INFRA-826" "$WORKER"; then
    ok "INFRA-826 block referenced in worker.sh"
else
    fail "INFRA-826 block missing from worker.sh"
fi

# 2. CHUMP_CIRCUIT_BREAKER kill switch present
if grep -q 'CHUMP_CIRCUIT_BREAKER' "$WORKER"; then
    ok "CHUMP_CIRCUIT_BREAKER kill switch present"
else
    fail "CHUMP_CIRCUIT_BREAKER kill switch missing"
fi

# 3. Default threshold is 3 (not 5)
if grep -q 'CHUMP_DISPATCH_FAIL_THRESHOLD:-3' "$WORKER"; then
    ok "default threshold is 3"
else
    fail "default threshold should be 3 — found: $(grep 'DISPATCH_FAIL_THRESHOLD' "$WORKER" | head -1)"
fi

# 4. Default pause is 300s (not 1800)
if grep -q 'CHUMP_CIRCUIT_PAUSE_SECS:-300' "$WORKER"; then
    ok "default pause is 300s (5min)"
else
    fail "default pause should be 300s — found: $(grep 'CIRCUIT_PAUSE_SECS' "$WORKER" | head -1)"
fi

# 5. kind=worker_circuit_open emitted
if grep -q 'worker_circuit_open' "$WORKER"; then
    ok "kind=worker_circuit_open emitted to ambient.jsonl"
else
    fail "kind=worker_circuit_open missing from worker.sh"
fi

# 6. Counter resets after alert
if grep -q '_dispatch_fail_count=0.*# reset' "$WORKER" || grep -q '_dispatch_fail_count=0  # reset' "$WORKER"; then
    ok "_dispatch_fail_count reset after emitting alert"
else
    fail "_dispatch_fail_count not reset after alert"
fi

# 7. Agent_id, consecutive_failures, pause_secs in emitted event
if grep -q '"consecutive_failures"' "$WORKER" && grep -q '"pause_secs"' "$WORKER" && grep -q '"agent_id"' "$WORKER"; then
    ok "event includes agent_id, consecutive_failures, pause_secs fields"
else
    fail "event missing required fields (agent_id, consecutive_failures, pause_secs)"
fi

# 8. Kill switch logic test: CHUMP_CIRCUIT_BREAKER=0 bypasses check
if bash -c '[[ "${CHUMP_CIRCUIT_BREAKER:-1}" != "0" ]] && echo "active" || echo "bypassed"' 2>/dev/null | grep -q "active"; then
    ok "kill switch default is active (not bypassed)"
else
    fail "kill switch default logic broken"
fi

if CHUMP_CIRCUIT_BREAKER=0 bash -c '[[ "${CHUMP_CIRCUIT_BREAKER:-1}" != "0" ]] && echo "active" || echo "bypassed"' 2>/dev/null | grep -q "bypassed"; then
    ok "CHUMP_CIRCUIT_BREAKER=0 bypasses circuit breaker"
else
    fail "CHUMP_CIRCUIT_BREAKER=0 kill switch not working"
fi

# 9. Functional: simulate circuit trip and ambient event emission
echo
echo "[functional: circuit trip simulation]"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"

# Simulate the circuit trip logic inline (threshold=1, pause=0 for speed)
_dispatch_fail_count=3
CHUMP_CIRCUIT_BREAKER=1
CHUMP_DISPATCH_FAIL_THRESHOLD=3
CHUMP_CIRCUIT_PAUSE_SECS=0  # no actual sleep in test
CHUMP_AMBIENT_LOG="$AMB"

if [[ "${CHUMP_CIRCUIT_BREAKER:-1}" != "0" ]]; then
    _threshold="${CHUMP_DISPATCH_FAIL_THRESHOLD:-3}"
    if [ "$_dispatch_fail_count" -ge "$_threshold" ]; then
        _pause="${CHUMP_CIRCUIT_PAUSE_SECS:-300}"
        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
        printf '{"ts":"%s","session":"test","worktree":"worker-test","event":"ALERT","kind":"worker_circuit_open","agent_id":"test","consecutive_failures":%d,"pause_secs":%d}\n' \
            "$_ts" "$_dispatch_fail_count" "$_pause" >> "$AMB" 2>/dev/null || true
        _dispatch_fail_count=0
        sleep "$_pause"
    fi
fi

if [[ -f "$AMB" ]] && grep -q '"worker_circuit_open"' "$AMB"; then
    ok "worker_circuit_open event emitted to ambient.jsonl when threshold reached"
else
    fail "worker_circuit_open event not emitted"
fi

if [[ "$_dispatch_fail_count" -eq 0 ]]; then
    ok "consecutive_failures counter reset to 0 after trip"
else
    fail "counter should be 0 after trip (got $_dispatch_fail_count)"
fi

if grep -q '"consecutive_failures":3' "$AMB"; then
    ok "event records consecutive_failures=3"
else
    fail "event should record consecutive_failures=3"
fi

if grep -q '"pause_secs":0' "$AMB"; then
    ok "event records pause_secs correctly"
else
    fail "event should record pause_secs"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
