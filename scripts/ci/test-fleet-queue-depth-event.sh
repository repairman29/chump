#!/usr/bin/env bash
# INFRA-558: fleet_queue_depth event emits via ambient-emit.sh with valid schema.
#
# Run from repo root: bash scripts/ci/test-fleet-queue-depth-event.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
LOG="$SANDBOX/ambient.jsonl"

run_emit() {
    local expected="$1"; shift
    local desc="$1"; shift
    : > "$LOG"
    local actual=0
    CHUMP_AMBIENT_LOG="$LOG" "$EMIT" "$@" 2>/dev/null || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        fail "$desc — expected exit $expected, got $actual"
        return
    fi
    if [[ "$expected" -eq 0 && ! -s "$LOG" ]]; then
        fail "$desc — expected line written, log is empty"
        return
    fi
    pass "$desc"
}

# Valid: all three required fields present
run_emit 0 "fleet_queue_depth with all fields" \
    fleet_queue_depth "pickable_count=5" "p0_count=2" "oldest_p0_age_days=3"

# Valid: zero values are fine
run_emit 0 "fleet_queue_depth with zero counts" \
    fleet_queue_depth "pickable_count=0" "p0_count=0" "oldest_p0_age_days=0"

# Invalid: missing pickable_count
run_emit 1 "fleet_queue_depth missing pickable_count" \
    fleet_queue_depth "p0_count=2" "oldest_p0_age_days=3"

# Invalid: missing p0_count
run_emit 1 "fleet_queue_depth missing p0_count" \
    fleet_queue_depth "pickable_count=5" "oldest_p0_age_days=3"

# Invalid: missing oldest_p0_age_days
run_emit 1 "fleet_queue_depth missing oldest_p0_age_days" \
    fleet_queue_depth "pickable_count=5" "p0_count=2"

# Content check: emitted JSON contains expected fields
: > "$LOG"
CHUMP_AMBIENT_LOG="$LOG" "$EMIT" fleet_queue_depth \
    "pickable_count=7" "p0_count=1" "oldest_p0_age_days=14" 2>/dev/null
line="$(cat "$LOG")"
for field in '"event":"fleet_queue_depth"' '"pickable_count":"7"' '"p0_count":"1"' '"oldest_p0_age_days":"14"'; do
    if echo "$line" | grep -qF "$field"; then
        pass "emitted JSON contains $field"
    else
        fail "emitted JSON missing $field — got: $line"
    fi
done

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
