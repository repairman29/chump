#!/usr/bin/env bash
# test-cascade-cancellation-status-description.sh — INFRA-5430
#
# Verifies the "cascade-cancellation" status description text built by the
# `test` job in .github/workflows/ci.yml (INFRA-1002 classification +
# INFRA-5430 status-posting). The description must be human-readable,
# name the cancelled jobs, and name the cause — without digging into
# workflow run logs — and must respect GitHub's 140-char status
# description cap.
#
# This duplicates the description-building snippet from ci.yml (the same
# pattern test-rollup-cascade-cancel.sh already uses for the classification
# logic) so the string format can be asserted without running real CI.

set -euo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

build_desc() {
    local real_failures="$1" cascade_cancels="$2" supersedure_cancels="$3"
    local cascade_desc
    if [ -n "$cascade_cancels" ]; then
        cascade_desc="Cancelled (caused by failure in: ${real_failures}): ${cascade_cancels}"
    else
        cascade_desc="Cancelled (superseded by newer run on same SHA): ${supersedure_cancels}"
    fi
    cascade_desc="${cascade_desc:0:140}"
    printf '%s' "$cascade_desc"
}

# ── Test 1: cascade cancel names both the failing job and cancelled jobs ────
DESC1=$(build_desc "fast-checks" "clippy,cargo-test" "")
echo "$DESC1" | grep -q "fast-checks" || fail "Test 1: cause (fast-checks) missing from description: $DESC1"
echo "$DESC1" | grep -q "clippy,cargo-test" || fail "Test 1: cancelled jobs missing from description: $DESC1"
pass "Test 1: cascade description names cause + cancelled jobs ($DESC1)"

# ── Test 2: supersedure cancel names the reason, not a failing job ─────────
DESC2=$(build_desc "" "" "fast-checks,clippy,cargo-test,pr-hygiene")
echo "$DESC2" | grep -q "superseded" || fail "Test 2: supersedure reason missing: $DESC2"
echo "$DESC2" | grep -q "fast-checks,clippy,cargo-test,pr-hygiene" || fail "Test 2: cancelled jobs missing: $DESC2"
pass "Test 2: supersedure description names reason + cancelled jobs ($DESC2)"

# ── Test 3: description respects GitHub's 140-char status cap ─────────────
LONG_LIST="job-with-a-very-long-name-one,job-with-a-very-long-name-two,job-with-a-very-long-name-three,job-with-a-very-long-name-four,job-with-a-very-long-name-five"
DESC3=$(build_desc "some-failing-job-with-a-long-name-too" "$LONG_LIST" "")
LEN3=${#DESC3}
[ "$LEN3" -le 140 ] || fail "Test 3: description exceeds 140 chars (got $LEN3): $DESC3"
pass "Test 3: long description truncated to <=140 chars (len=$LEN3)"

echo ""
echo "All INFRA-5430 cascade-cancellation status description checks passed (3/3)."
