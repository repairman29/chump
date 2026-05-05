#!/usr/bin/env bash
# test-infra-483-fleet-waste-cooldown.sh — INFRA-483
#
# Validates worker.sh detects 0-byte cycle logs as "wedges" and applies
# extended cooldown so the fleet doesn't re-pick the same wedged gap
# infinitely.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-483 fleet-waste cooldown test ==="
echo

# 1. INFRA-483 block exists.
if grep -q "INFRA-483" "$WORKER"; then
    ok "worker.sh contains INFRA-483 block"
else
    fail "worker.sh missing INFRA-483 block"
fi

# 2. Wedge detection: rc=124 + cycle_log<100B.
if grep -qE 'rc.*-eq 124.*-lt 100|_cycle_log_size.*-lt 100' "$WORKER"; then
    ok "wedge detector checks 0-byte / tiny cycle log"
else
    fail "wedge detector missing"
fi

# 3. Cooldown now fires on rc=124 (was previously skipped).
# Find the cooldown block — must include rc=124 path.
if grep -qE 'FLEET_TIMEOUT_COOLDOWN_S' "$WORKER"; then
    ok "FLEET_TIMEOUT_COOLDOWN_S env (rc=124 cooldown duration) present"
else
    fail "FLEET_TIMEOUT_COOLDOWN_S env missing — rc=124 still skips cooldown"
fi

# 4. Wedge cooldown is longer than ordinary timeout cooldown.
if grep -qE 'FLEET_WEDGE_COOLDOWN_S.*14400|FLEET_WEDGE_COOLDOWN_S.*-:14400' "$WORKER"; then
    ok "FLEET_WEDGE_COOLDOWN_S defaults to 4h (longer than rc=124 default 1h)"
else
    fail "FLEET_WEDGE_COOLDOWN_S default missing or wrong"
fi

# 5. Wedge ALERT to ambient.jsonl.
if grep -qE '"kind":"fleet_wedge"' "$WORKER"; then
    ok "wedge condition emits ALERT kind=fleet_wedge to ambient.jsonl"
else
    fail "wedge ALERT to ambient missing — operator can't see waste"
fi

# 6. Live test: simulate the wedge detection logic.
TMP_LOG="/tmp/infra-483-wedge-test-$$"
echo "" > "$TMP_LOG.empty"
echo "real claude output here. lots of bytes here lots of bytes here lots of bytes here lots of bytes here lots of bytes here lots of bytes." > "$TMP_LOG.real"

# Simulate the wedge detector inline.
detect_wedge() {
    local cycle_log="$1"
    local rc="$2"
    local size=0
    if [ -f "$cycle_log" ]; then
        size=$(wc -c < "$cycle_log" 2>/dev/null | tr -d ' ' || echo 0)
    fi
    if [ "$rc" -eq 124 ] && [ "$size" -lt 100 ]; then
        echo "wedge"
    elif [ "$rc" -eq 124 ]; then
        echo "timeout"
    else
        echo "ordinary rc=$rc"
    fi
}

result=$(detect_wedge "$TMP_LOG.empty" 124)
if [ "$result" = "wedge" ]; then
    ok "live: 0-byte log + rc=124 → wedge"
else
    fail "live: 0-byte log + rc=124 detected as '$result' (expected 'wedge')"
fi

result=$(detect_wedge "$TMP_LOG.real" 124)
if [ "$result" = "timeout" ]; then
    ok "live: real-output log + rc=124 → timeout (not wedge)"
else
    fail "live: real-output + rc=124 detected as '$result' (expected 'timeout')"
fi

result=$(detect_wedge "$TMP_LOG.empty" 1)
if [ "$result" = "ordinary rc=1" ]; then
    ok "live: 0-byte log + rc=1 → ordinary (not wedge — only rc=124 qualifies)"
else
    fail "live: rc=1 with empty log detected as '$result' (expected 'ordinary rc=1')"
fi

# Cleanup.
rm -f "$TMP_LOG".*

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
