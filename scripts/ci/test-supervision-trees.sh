#!/usr/bin/env bash
# test-supervision-trees.sh — RESILIENT-058 regression test
#
# Simulates the 2026-06-03 12-zombie audit incident as a parameterized fixture:
#   12 CI audit runs stuck IN_PROGRESS for 25+ min on 4 runners, no supervisor
#   to catch the retry-storm. Operator had to manually cancel 12 runs via
#   gh run cancel. This test asserts the supervision tree halts at threshold,
#   not at restart #12.
#
# Test plan:
#   Test 1: per-gap escalation — 4th restart triggers rc=1 + gap blocked + event
#   Test 2: fleet escalation — 2 gap-supervisor escalations trigger pickup pause
#   Test 3: 12-zombie audit fixture — 12 restarts, halts at 3, pauses at 2nd esc.
#   Test 4: recovery via fleet-doctor-strict (mocked to rc=0)
#
# Usage:
#   bash scripts/ci/test-supervision-trees.sh
#
# Environment:
#   CHUMP_GAP_SUPERVISOR_MAX_RESTARTS  override threshold (default 3)
#   CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS  override threshold (default 2)
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GAP_SUP="$REPO_ROOT/scripts/coord/gap-supervisor.sh"
FLEET_SUP="$REPO_ROOT/scripts/coord/fleet-supervisor.sh"

PASS=0
FAIL=0
SKIP=0

# ── Test helpers ───────────────────────────────────────────────────────────────

pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
skip() { echo "  SKIP: $*"; SKIP=$(( SKIP + 1 )); }

# Isolated scratch environment for each test.
make_env() {
    local dir="${TMPDIR:-/tmp}/chump-sup-test-$$-${RANDOM}"
    mkdir -p "$dir"
    echo "$dir"
}

cleanup_env() {
    local dir="$1"
    rm -rf "$dir" 2>/dev/null || true
}

# Run gap-supervisor.sh with an isolated state file + ambient log.
run_gap_sup() {
    local scratch="$1"; shift
    CHUMP_GAP_SUPERVISOR_STATE="$scratch/.gap-supervisor-state.jsonl" \
    CHUMP_AMBIENT_LOG="$scratch/ambient.jsonl" \
    CHUMP_BIN="false" \
    bash "$GAP_SUP" "$@"
}

# Run fleet-supervisor.sh with an isolated ambient log + sentinel.
run_fleet_sup() {
    local scratch="$1"; shift
    CHUMP_AMBIENT_LOG="$scratch/ambient.jsonl" \
    CHUMP_FLEET_PICKUP_SENTINEL="$scratch/.fleet-pickup-paused" \
    bash "$FLEET_SUP" "$@"
}

count_kind() {
    local file="$1"
    local kind="$2"
    [[ -f "$file" ]] || { echo 0; return; }
    grep -c "\"kind\":\"${kind}\"" "$file" 2>/dev/null || echo 0
}

# ── Test 1: per-gap escalation ────────────────────────────────────────────────

echo
echo "=== Test 1: per-gap escalation ==="
echo "  Expect: 4th 'record TEST-001' call returns rc=1 + kind=gap_supervisor_escalated emitted"

T1="$(make_env)"

# Override thresholds for speed: 3 restarts / 5-min window (defaults).
export CHUMP_GAP_SUPERVISOR_MAX_RESTARTS=3
export CHUMP_GAP_SUPERVISOR_WINDOW_S=300

T1_RC1=0; run_gap_sup "$T1" record TEST-001 >/dev/null 2>&1 || T1_RC1=$?
T1_RC2=0; run_gap_sup "$T1" record TEST-001 >/dev/null 2>&1 || T1_RC2=$?
T1_RC3=0; run_gap_sup "$T1" record TEST-001 >/dev/null 2>&1 || T1_RC3=$?
T1_RC4=0; run_gap_sup "$T1" record TEST-001 >/dev/null 2>&1 || T1_RC4=$?

if [[ "$T1_RC1" -eq 0 && "$T1_RC2" -eq 0 && "$T1_RC3" -eq 0 ]]; then
    pass "restarts 1-3 returned rc=0 (allowed)"
else
    fail "restarts 1-3 should all return rc=0 (got $T1_RC1/$T1_RC2/$T1_RC3)"
fi

if [[ "$T1_RC4" -eq 1 ]]; then
    pass "4th restart returned rc=1 (escalation triggered)"
else
    fail "4th restart should return rc=1 (got rc=$T1_RC4)"
fi

ESC_COUNT="$(count_kind "$T1/ambient.jsonl" "gap_supervisor_escalated")"
if [[ "$ESC_COUNT" -ge 1 ]]; then
    pass "kind=gap_supervisor_escalated emitted in ambient ($ESC_COUNT event(s))"
else
    fail "kind=gap_supervisor_escalated NOT found in ambient (got $ESC_COUNT)"
fi

HB_COUNT="$(count_kind "$T1/ambient.jsonl" "gap_supervisor_heartbeat")"
if [[ "$HB_COUNT" -ge 1 ]]; then
    pass "kind=gap_supervisor_heartbeat emitted ($HB_COUNT event(s))"
else
    fail "kind=gap_supervisor_heartbeat NOT found in ambient"
fi

cleanup_env "$T1"

# ── Test 2: fleet escalation ──────────────────────────────────────────────────

echo
echo "=== Test 2: fleet escalation ==="
echo "  Expect: 2 escalations trigger fleet pickup pause sentinel"

T2="$(make_env)"

export CHUMP_GAP_SUPERVISOR_MAX_RESTARTS=3
export CHUMP_GAP_SUPERVISOR_WINDOW_S=300
export CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS=2
export CHUMP_FLEET_SUPERVISOR_WINDOW_S=600

# Trigger escalation #1 by pushing TEST-002 to threshold.
run_gap_sup "$T2" record TEST-002 >/dev/null 2>&1 || true
run_gap_sup "$T2" record TEST-002 >/dev/null 2>&1 || true
run_gap_sup "$T2" record TEST-002 >/dev/null 2>&1 || true
run_gap_sup "$T2" record TEST-002 >/dev/null 2>&1 || true  # escalation #1 fires

# Trigger escalation #2 by pushing TEST-003 to threshold.
run_gap_sup "$T2" record TEST-003 >/dev/null 2>&1 || true
run_gap_sup "$T2" record TEST-003 >/dev/null 2>&1 || true
run_gap_sup "$T2" record TEST-003 >/dev/null 2>&1 || true
run_gap_sup "$T2" record TEST-003 >/dev/null 2>&1 || true  # escalation #2 fires

ESC2_COUNT="$(count_kind "$T2/ambient.jsonl" "gap_supervisor_escalated")"
if [[ "$ESC2_COUNT" -ge 2 ]]; then
    pass "2 gap_supervisor_escalated events in ambient (got $ESC2_COUNT)"
else
    fail "Expected >=2 gap_supervisor_escalated events (got $ESC2_COUNT)"
fi

# Now fleet supervisor tick — should detect 2 escalations and pause pickup.
CHUMP_FLEET_DOCTOR_SCRIPT="false" \
    run_fleet_sup "$T2" tick >/dev/null 2>&1 || true

SENTINEL_FILE="$T2/.fleet-pickup-paused"
if [[ -f "$SENTINEL_FILE" ]]; then
    pass ".fleet-pickup-paused sentinel file created"
else
    fail ".fleet-pickup-paused sentinel file NOT created after 2 escalations"
fi

PAUSE_COUNT="$(count_kind "$T2/ambient.jsonl" "fleet_supervisor_pickup_paused")"
if [[ "$PAUSE_COUNT" -ge 1 ]]; then
    pass "kind=fleet_supervisor_pickup_paused emitted ($PAUSE_COUNT event(s))"
else
    fail "kind=fleet_supervisor_pickup_paused NOT emitted"
fi

HB2_COUNT="$(count_kind "$T2/ambient.jsonl" "fleet_supervisor_heartbeat")"
if [[ "$HB2_COUNT" -ge 1 ]]; then
    pass "kind=fleet_supervisor_heartbeat emitted ($HB2_COUNT event(s))"
else
    fail "kind=fleet_supervisor_heartbeat NOT emitted"
fi

cleanup_env "$T2"

# ── Test 3: 12-zombie audit fixture ──────────────────────────────────────────

echo
echo "=== Test 3: 12-zombie audit fixture (2026-06-03 incident parameterized) ==="
echo "  Simulate 12 restart events on AUDIT-JOB-001 within window."
echo "  Assert: supervisor HALTS at restart #3 (not #12)."
echo "  Assert: fleet PAUSES after 2nd escalation (not after 12th)."

T3="$(make_env)"

export CHUMP_GAP_SUPERVISOR_MAX_RESTARTS=3
export CHUMP_GAP_SUPERVISOR_WINDOW_S=300
export CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS=2
export CHUMP_FLEET_SUPERVISOR_WINDOW_S=600

# Simulate 12 restart events — the 2026-06-03 audit-run zombie count.
HALT_AT=0
for i in $(seq 1 12); do
    RC=0
    run_gap_sup "$T3" record AUDIT-JOB-001 >/dev/null 2>&1 || RC=$?
    if [[ "$RC" -eq 1 && "$HALT_AT" -eq 0 ]]; then
        HALT_AT=$i
    fi
done

# Escalation fires on the (MAX_RESTARTS+1)th restart: MAX_RESTARTS are allowed,
# the next one exceeds the threshold. With default MAX_RESTARTS=3, halt at #4.
EXPECTED_HALT=$(( CHUMP_GAP_SUPERVISOR_MAX_RESTARTS + 1 ))
if [[ "$HALT_AT" -eq "$EXPECTED_HALT" ]]; then
    pass "per-gap supervisor halted at restart #${HALT_AT} (allowed $CHUMP_GAP_SUPERVISOR_MAX_RESTARTS, blocked on #${EXPECTED_HALT}) — NOT at restart #12"
elif [[ "$HALT_AT" -gt 0 ]]; then
    fail "supervisor halted at restart #${HALT_AT} (expected #${EXPECTED_HALT} = MAX_RESTARTS+1)"
else
    fail "supervisor never halted across 12 restarts (expected halt at #${EXPECTED_HALT})"
fi

T3_ESC="$(count_kind "$T3/ambient.jsonl" "gap_supervisor_escalated")"
if [[ "$T3_ESC" -ge 1 ]]; then
    pass "gap_supervisor_escalated emitted after halt ($T3_ESC event(s))"
else
    fail "gap_supervisor_escalated NOT emitted"
fi

# Now trigger a second gap's escalation for fleet-level test.
for i in $(seq 1 4); do
    run_gap_sup "$T3" record AUDIT-JOB-002 >/dev/null 2>&1 || true
done

T3_ESC_TOTAL="$(count_kind "$T3/ambient.jsonl" "gap_supervisor_escalated")"
if [[ "$T3_ESC_TOTAL" -ge 2 ]]; then
    pass "2nd gap_supervisor_escalated event present ($T3_ESC_TOTAL total) — fleet threshold reachable"
else
    fail "Expected 2nd escalation from AUDIT-JOB-002 (total: $T3_ESC_TOTAL)"
fi

# Fleet supervisor tick — should pause on 2 escalations.
CHUMP_FLEET_DOCTOR_SCRIPT="false" \
    run_fleet_sup "$T3" tick >/dev/null 2>&1 || true

T3_SENTINEL="$T3/.fleet-pickup-paused"
if [[ -f "$T3_SENTINEL" ]]; then
    pass "fleet pickup paused after 2nd escalation (NOT after 12th restart)"
else
    fail "fleet pickup sentinel NOT created — supervisor failed to pause"
fi

# Verify the sentinel contains the expected gap IDs.
SENTINEL_GAP_IDS="$(python3 -c "
import json
try:
    with open('$T3_SENTINEL') as f:
        d = json.load(f)
    ids = d.get('gap_ids', [])
    print(','.join(sorted(ids)))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null || echo "ERR:read-failed")"

if echo "$SENTINEL_GAP_IDS" | grep -q "AUDIT-JOB-001"; then
    pass "sentinel records AUDIT-JOB-001 as an escalated gap"
else
    fail "sentinel gap_ids missing AUDIT-JOB-001 (got: $SENTINEL_GAP_IDS)"
fi

cleanup_env "$T3"

# ── Test 4: recovery via fleet-doctor-strict (mocked rc=0) ───────────────────

echo
echo "=== Test 4: recovery via fleet-doctor-strict (mocked to rc=0) ==="

T4="$(make_env)"

export CHUMP_FLEET_SUPERVISOR_MAX_ESCALATIONS=2
export CHUMP_FLEET_SUPERVISOR_WINDOW_S=600

# Create a pre-existing pause sentinel (simulating already-paused state).
python3 -c "
import json
sentinel = {
    'ts': '2026-06-03T07:35:00Z',
    'escalation_count': 2,
    'gap_ids': ['AUDIT-JOB-001', 'AUDIT-JOB-002'],
    'reason': 'test: simulated pause',
    'recovery': 'run: bash scripts/coord/fleet-supervisor.sh resume-attempt'
}
print(json.dumps(sentinel))
" > "$T4/.fleet-pickup-paused" 2>/dev/null

# Create a mock fleet-doctor-strict that always returns 0.
MOCK_DOCTOR="$T4/mock-fleet-doctor.sh"
printf '#!/usr/bin/env bash\n# Mock fleet-doctor-strict: always passes\nexit 0\n' > "$MOCK_DOCTOR"
chmod +x "$MOCK_DOCTOR"

# Attempt recovery.
CHUMP_FLEET_PICKUP_SENTINEL="$T4/.fleet-pickup-paused" \
CHUMP_AMBIENT_LOG="$T4/ambient.jsonl" \
CHUMP_FLEET_DOCTOR_SCRIPT="$MOCK_DOCTOR" \
    bash "$FLEET_SUP" resume-attempt >/dev/null 2>&1

if [[ ! -f "$T4/.fleet-pickup-paused" ]]; then
    pass "sentinel removed after mock fleet-doctor-strict passed"
else
    fail "sentinel still exists after successful recovery (expected removal)"
fi

RESUMED_COUNT="$(count_kind "$T4/ambient.jsonl" "fleet_pickup_resumed")"
if [[ "$RESUMED_COUNT" -ge 1 ]]; then
    pass "kind=fleet_pickup_resumed emitted ($RESUMED_COUNT event(s))"
else
    fail "kind=fleet_pickup_resumed NOT emitted"
fi

# Sub-test 4b: recovery fails when fleet-doctor-strict returns non-zero.
echo "  Sub-test 4b: recovery with fleet-doctor-strict returning rc=1"

python3 -c "
import json
sentinel = {
    'ts': '2026-06-03T07:35:00Z',
    'escalation_count': 2,
    'gap_ids': ['AUDIT-JOB-001'],
    'reason': 'test: simulated pause for sub-test 4b',
    'recovery': 'run: bash scripts/coord/fleet-supervisor.sh resume-attempt'
}
print(json.dumps(sentinel))
" > "$T4/.fleet-pickup-paused" 2>/dev/null

MOCK_DOCTOR_FAIL="$T4/mock-fleet-doctor-fail.sh"
printf '#!/usr/bin/env bash\n# Mock fleet-doctor-strict: fails\necho '"'"'{"pass":0,"fail":1,"checks":[{"name":"disk","status":"fail","detail":"low disk"}]}'"'"'\nexit 1\n' > "$MOCK_DOCTOR_FAIL"
chmod +x "$MOCK_DOCTOR_FAIL"

CHUMP_FLEET_PICKUP_SENTINEL="$T4/.fleet-pickup-paused" \
CHUMP_AMBIENT_LOG="$T4/ambient.jsonl" \
CHUMP_FLEET_DOCTOR_SCRIPT="$MOCK_DOCTOR_FAIL" \
    bash "$FLEET_SUP" resume-attempt >/dev/null 2>&1 || true

if [[ -f "$T4/.fleet-pickup-paused" ]]; then
    pass "sentinel preserved when fleet-doctor-strict fails (pickup remains paused)"
else
    fail "sentinel was removed even though fleet-doctor-strict failed (pickup should stay paused)"
fi

FAILED_COUNT="$(count_kind "$T4/ambient.jsonl" "fleet_doctor_strict_failed")"
if [[ "$FAILED_COUNT" -ge 1 ]]; then
    pass "kind=fleet_doctor_strict_failed emitted ($FAILED_COUNT event(s))"
else
    fail "kind=fleet_doctor_strict_failed NOT emitted after recovery failure"
fi

cleanup_env "$T4"

# ── Summary ────────────────────────────────────────────────────────────────────

echo
echo "=== test-supervision-trees.sh summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"
echo

if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: $FAIL test(s) failed" >&2
    exit 1
fi

echo "OK: all supervision-tree tests passed"
exit 0
