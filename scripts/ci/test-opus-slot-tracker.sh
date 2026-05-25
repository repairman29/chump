#!/usr/bin/env bash
# test-opus-slot-tracker.sh — META-093 smoke test
#
# Verifies opus-slot-tracker.sh behavior:
#   1. 3-slot dispatch + capacity check fires at slot 4
#   2. Stalled slot (no lease after 5min) triggers kill+release
#   3. kind=opus_slot_reaped emitted to ambient with {gap_id, slot_id, reap_reason}
#   4. Bypass modes (CHUMP_OPUS_MAX_SLOTS=0 / =1) work correctly
#   5. Manual release removes slot from state
#
# Usage:
#   bash scripts/ci/test-opus-slot-tracker.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/opus-slot-tracker.sh"

PASS=0
FAIL=0
FAILURES=()

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        (( PASS++ )) || true
    else
        echo "  FAIL: $desc"
        (( FAIL++ )) || true
        FAILURES+=("$desc")
    fi
}

check_output_contains() {
    local desc="$1"
    local pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1 || true)
    if echo "$out" | grep -q "$pattern"; then
        echo "  PASS: $desc"
        (( PASS++ )) || true
    else
        echo "  FAIL: $desc (expected pattern '$pattern' in output)"
        echo "    actual output: $out" | head -5
        (( FAIL++ )) || true
        FAILURES+=("$desc")
    fi
}

check_exit_nonzero() {
    local desc="$1"; shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        echo "  PASS: $desc (exit $rc)"
        (( PASS++ )) || true
    else
        echo "  FAIL: $desc (expected non-zero exit, got 0)"
        (( FAIL++ )) || true
        FAILURES+=("$desc")
    fi
}

echo "=== test-opus-slot-tracker.sh ==="
echo ""

# ── Setup: temp environment ────────────────────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

SLOTS_FILE="$TMPDIR_TEST/opus-slots.json"
AMBIENT_FILE="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_OPUS_SLOTS_FILE="$SLOTS_FILE"
export CHUMP_AMBIENT_LOG="$AMBIENT_FILE"
export CHUMP_SESSION_ID="test-session-$$"

# ── Test 1: status on empty state ─────────────────────────────────────────

echo "[1] Status on empty state"
check_output_contains "status shows 0 slots" "free" \
    bash "$SCRIPT" status

# ── Test 2: dispatch 3 slots ──────────────────────────────────────────────

echo ""
echo "[2] Dispatch 3 slots (capacity cap)"

check_output_contains "dispatch slot 1 for TEST-001" "Dispatched slot 1" \
    bash "$SCRIPT" dispatch TEST-001

check_output_contains "dispatch slot 2 for TEST-002" "Dispatched slot 2" \
    bash "$SCRIPT" dispatch TEST-002

check_output_contains "dispatch slot 3 for TEST-003" "Dispatched slot 3" \
    bash "$SCRIPT" dispatch TEST-003

# Now slots are full — 4th dispatch must fail with CAPACITY FULL
check_exit_nonzero "4th dispatch fails capacity check" \
    bash "$SCRIPT" dispatch TEST-004

check_output_contains "4th dispatch error message includes CAPACITY FULL" "CAPACITY FULL" \
    bash "$SCRIPT" dispatch TEST-004

# ── Test 3: status shows 3 in-flight ─────────────────────────────────────

echo ""
echo "[3] Status shows 3 in-flight slots"
check_output_contains "status shows 3 slots" "In-flight slots: 3" \
    bash "$SCRIPT" status

check_output_contains "status shows TEST-001" "TEST-001" \
    bash "$SCRIPT" status

check_output_contains "status shows TEST-002" "TEST-002" \
    bash "$SCRIPT" status

check_output_contains "status shows TEST-003" "TEST-003" \
    bash "$SCRIPT" status

# ── Test 4: stalled slot reap (synthetic past timestamps) ─────────────────

echo ""
echo "[4] Stalled slot — no lease after 5min → kill+release"

# Inject a synthetic stalled slot: dispatched 10 min ago, no lease
STALL_TS=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

python3 - <<PYEOF
import json
SLOTS_FILE = "$SLOTS_FILE"
STALL_TS = "$STALL_TS"

# Replace all slots with a single stalled slot for clean reap test
slots = [{
    "slot_id": 1,
    "agent_id": "sonnet-slot-1-stalled",
    "gap_id": "STALL-001",
    "dispatched_ts": STALL_TS,
    "last_progress_ts": STALL_TS,
    "lease_confirmed": False,
    "pr_number": None,
}]
with open(SLOTS_FILE, "w") as f:
    json.dump(slots, f, indent=2)
PYEOF

# Clear ambient before reap so we can check fresh emit
> "$AMBIENT_FILE"

check_output_contains "reap detects stalled slot" "REAPING" \
    bash "$SCRIPT" reap

# ── Test 5: ambient event emitted for reap ───────────────────────────────

echo ""
echo "[5] opus_slot_reaped emitted to ambient"

check "ambient file has content after reap" test -s "$AMBIENT_FILE"

check_output_contains "kind=opus_slot_reaped in ambient" "opus_slot_reaped" \
    cat "$AMBIENT_FILE"

check_output_contains "gap_id in reaped event" "STALL-001" \
    cat "$AMBIENT_FILE"

check_output_contains "reap_reason in reaped event" "no_lease" \
    cat "$AMBIENT_FILE"

check_output_contains "slot_id in reaped event" "slot_id" \
    cat "$AMBIENT_FILE"

# Verify valid JSON in the reaped event
check "reaped ambient event is valid JSON" python3 -c "
import json
with open('$AMBIENT_FILE') as f:
    for line in f:
        line = line.strip()
        if line:
            obj = json.loads(line)
            assert obj.get('kind') == 'opus_slot_reaped', f'unexpected kind: {obj}'
"

# ── Test 6: after reap, slot freed ───────────────────────────────────────

echo ""
echo "[6] After reap, slot is freed"
check_output_contains "status shows 0 after reap" "No active slots" \
    bash "$SCRIPT" status

# ── Test 7: opus_slot_dispatched emitted on dispatch ─────────────────────

echo ""
echo "[7] opus_slot_dispatched emitted to ambient on dispatch"

> "$AMBIENT_FILE"

bash "$SCRIPT" dispatch EMIT-TEST-001 >/dev/null 2>&1

check_output_contains "kind=opus_slot_dispatched in ambient" "opus_slot_dispatched" \
    cat "$AMBIENT_FILE"

check_output_contains "gap_id in dispatched event" "EMIT-TEST-001" \
    cat "$AMBIENT_FILE"

# ── Test 8: manual release ────────────────────────────────────────────────

echo ""
echo "[8] Manual release removes slot"

# Dispatch another slot so we have one to release
bash "$SCRIPT" dispatch RELEASE-TEST-001 >/dev/null 2>&1 || true
bash "$SCRIPT" dispatch RELEASE-TEST-002 >/dev/null 2>&1 || true

# Get slot count before release
local_count=$(python3 -c "import json; print(len(json.load(open('$SLOTS_FILE'))))" 2>/dev/null || echo 0)

# Release slot 1
bash "$SCRIPT" release 1 >/dev/null 2>&1 || true

new_count=$(python3 -c "import json; print(len(json.load(open('$SLOTS_FILE'))))" 2>/dev/null || echo 0)

check "release decrements slot count" test "$new_count" -lt "$local_count"

# Slot 2 should still be live (we released 1 above); check its release message
check_output_contains "release reports success" "Released slot 2" \
    bash "$SCRIPT" release 2

# ── Test 9: CHUMP_OPUS_MAX_SLOTS=0 bypass ────────────────────────────────

echo ""
echo "[9] CHUMP_OPUS_MAX_SLOTS=0 bypass"

check_output_contains "MAX_SLOTS=0 shows bypass in status" "BYPASS" \
    env CHUMP_OPUS_MAX_SLOTS=0 bash "$SCRIPT" status

check_output_contains "MAX_SLOTS=0 shows bypass in dispatch" "BYPASS" \
    env CHUMP_OPUS_MAX_SLOTS=0 bash "$SCRIPT" dispatch TEST-BYPASS

check_output_contains "MAX_SLOTS=0 shows bypass in reap" "BYPASS" \
    env CHUMP_OPUS_MAX_SLOTS=0 bash "$SCRIPT" reap

# ── Test 10: CHUMP_OPUS_MAX_SLOTS=1 single-slot legacy mode ──────────────

echo ""
echo "[10] CHUMP_OPUS_MAX_SLOTS=1 single-slot legacy mode"

# Clean slate
rm -f "$SLOTS_FILE"

bash "$SCRIPT" dispatch LEGACY-001 >/dev/null 2>&1 || true

check_exit_nonzero "2nd dispatch fails with max_slots=1" \
    env CHUMP_OPUS_MAX_SLOTS=1 bash "$SCRIPT" dispatch LEGACY-002

# ── Test 11: PR timeout trigger ───────────────────────────────────────────

echo ""
echo "[11] No PR after 10min triggers reap"

# Inject slot dispatched 12 min ago, lease confirmed but no PR
NO_PR_TS=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=12)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

python3 - <<PYEOF
import json
SLOTS_FILE = "$SLOTS_FILE"
NO_PR_TS = "$NO_PR_TS"

slots = [{
    "slot_id": 2,
    "agent_id": "sonnet-slot-2-nopr",
    "gap_id": "NOPR-001",
    "dispatched_ts": NO_PR_TS,
    "last_progress_ts": NO_PR_TS,
    "lease_confirmed": True,
    "pr_number": None,
}]
with open(SLOTS_FILE, "w") as f:
    json.dump(slots, f, indent=2)
PYEOF

> "$AMBIENT_FILE"

check_output_contains "reap detects no-PR slot" "REAPING" \
    bash "$SCRIPT" reap

check_output_contains "no_pr reason in ambient" "no_pr" \
    cat "$AMBIENT_FILE"

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if (( FAIL > 0 )); then
    echo ""
    echo "Failed assertions:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

echo ""
echo "All $PASS tests passed."
exit 0
