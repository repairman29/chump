#!/usr/bin/env bash
# test-strict-mode.sh — INFRA-1836 phase 1 smoke test.
#
# Exercises scripts/coord/lib/chump-strict-mode.sh helper.
# Verifies:
#   1. CHUMP_NO_BYPASS unset → _chump_check_no_bypass is a no-op (rc 0, no stderr).
#   2. CHUMP_NO_BYPASS=0 → still no-op.
#   3. CHUMP_NO_BYPASS=1 → exit 1, stderr contains the bypass_env name + 'strict mode'.
#   4. CHUMP_NO_BYPASS=1 → emits kind=no_bypass_violation to ambient with bypass_kind field.
#   5. _chump_strict_mode_active reflects env state (0 unset, 0 with =0, 0 with =1 [rc-shifted: 0 means active]).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/chump-strict-mode.sh"

[[ -r "$LIB" ]] || { echo "FAIL: $LIB not readable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_SESSION_ID="test-strict-mode-session"

# Helper: invoke _chump_check_no_bypass in a subshell so an exit 1 inside it
# doesn't terminate our test.
call_check() {
    # $1 env value for CHUMP_NO_BYPASS ("" to unset)
    # $2 bypass_env name
    # $3 would_have_skipped
    local env_val="$1" name="$2" desc="$3"
    if [[ -z "$env_val" ]]; then
        bash -c "
            unset CHUMP_NO_BYPASS
            source '$LIB'
            _chump_check_no_bypass '$name' '$desc'
            echo \"OK\"
        " 2>&1
    else
        bash -c "
            export CHUMP_NO_BYPASS='$env_val'
            export CHUMP_AMBIENT_LOG='$AMBIENT'
            export CHUMP_SESSION_ID='$CHUMP_SESSION_ID'
            source '$LIB'
            _chump_check_no_bypass '$name' '$desc'
            echo \"OK\"
        " 2>&1
    fi
}

# ── Test 1: CHUMP_NO_BYPASS unset → no-op ────────────────────────────────────
echo "Test 1: CHUMP_NO_BYPASS unset → no-op"
out=$(call_check "" "CHUMP_FMT_CHECK" "fmt check")
if [[ "$out" == *"OK"* && "$out" != *"strict mode"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected OK without strict-mode trip, got: $out"
    exit 1
fi

# ── Test 2: CHUMP_NO_BYPASS=0 → no-op ────────────────────────────────────────
# INFRA-2422: CHUMP_PREFLIGHT_SKIP deleted. Use CHUMP_FMT_CHECK (another
# bypass-class var) as the test subject — strict-mode does not care which var.
echo "Test 2: CHUMP_NO_BYPASS=0 → no-op"
out=$(call_check "0" "CHUMP_FMT_CHECK" "fmt check bypass")
if [[ "$out" == *"OK"* && "$out" != *"strict mode"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected no-op with =0, got: $out"
    exit 1
fi

# ── Test 3: CHUMP_NO_BYPASS=1 → exit 1 + diagnostic ──────────────────────────
echo "Test 3: CHUMP_NO_BYPASS=1 → exit 1 + diagnostic"
# call_check's subshell exits 1 by design in this test — capture without
# tripping set -e.
out=$(call_check "1" "CHUMP_TEST_GATE" "cargo test slow phase" || true)
# Should NOT see "OK" (because exit 1 fires before the echo).
if [[ "$out" != *"OK"* && "$out" == *"strict mode"* && "$out" == *"CHUMP_TEST_GATE"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected strict-mode trip with CHUMP_TEST_GATE name, got: $out"
    exit 1
fi

# ── Test 4: Test 3 emitted to ambient ────────────────────────────────────────
echo "Test 4: ambient emit kind=no_bypass_violation"
if grep -q '"kind":"no_bypass_violation"' "$AMBIENT" && \
   grep -q '"bypass_kind":"CHUMP_TEST_GATE"' "$AMBIENT" && \
   grep -q '"session":"test-strict-mode-session"' "$AMBIENT"; then
    echo "  PASS"
else
    echo "  FAIL: ambient missing expected fields"
    cat "$AMBIENT"
    exit 1
fi

# ── Test 5: _chump_strict_mode_active reflects env ───────────────────────────
echo "Test 5: _chump_strict_mode_active reflects env"
out_active=$(bash -c "export CHUMP_NO_BYPASS=1; source '$LIB'; if _chump_strict_mode_active; then echo ACTIVE; else echo INACTIVE; fi" 2>&1)
out_inactive=$(bash -c "unset CHUMP_NO_BYPASS; source '$LIB'; if _chump_strict_mode_active; then echo ACTIVE; else echo INACTIVE; fi" 2>&1)
out_zero=$(bash -c "export CHUMP_NO_BYPASS=0; source '$LIB'; if _chump_strict_mode_active; then echo ACTIVE; else echo INACTIVE; fi" 2>&1)
if [[ "$out_active" == "ACTIVE" && "$out_inactive" == "INACTIVE" && "$out_zero" == "INACTIVE" ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected ACTIVE / INACTIVE / INACTIVE, got: $out_active / $out_inactive / $out_zero"
    exit 1
fi

echo
echo "All 5 strict-mode smoke tests passed."
