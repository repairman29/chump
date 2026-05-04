#!/usr/bin/env bash
# INFRA-402 — `chump gap set --status done` must refuse without
# --closed-pr (or an existing non-zero closed_pr on the row).
#
# Pre-fix, the CLI silently wrote status=done to .chump/state.db without
# requiring closed_pr. The pre-commit guard (INFRA-107) catches this at
# the YAML diff layer, but `chump gap set` writes to the DB directly
# without necessarily emitting a YAML diff — so the guard never sees
# the violation. INFRA-339 closed via this path on 2026-05-03.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP="${CHUMP_BIN:-chump}"

if ! command -v "$CHUMP" >/dev/null 2>&1; then
    echo "(skipping — chump binary not on PATH)"; exit 0
fi

# Use a fixture state.db so we don't touch the real registry.
fixture=$(mktemp -d)
trap "rm -rf $fixture" EXIT
mkdir -p "$fixture/.chump"
cp "$REPO_ROOT/.chump/state.db" "$fixture/.chump/state.db"

# Pick an open gap that exists in the DB to test against.
test_id=$(sqlite3 "$fixture/.chump/state.db" \
    "SELECT id FROM gaps WHERE status='open' ORDER BY id LIMIT 1" 2>/dev/null)
if [[ -z "$test_id" ]]; then
    echo "(skipping — no open gap in fixture DB)"; exit 0
fi

cd "$fixture"

# 1. Without --closed-pr, status=done must FAIL.
out=$($CHUMP gap set "$test_id" --status done 2>&1) && rc=$? || rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "INFRA-402"; then
    pass "status=done without --closed-pr is refused with INFRA-402 message"
else
    fail "status=done without --closed-pr should fail (rc=$rc, out=$(echo "$out"|head -2))"
fi

# 2. DB still shows status=open (write was rejected).
db_status=$(sqlite3 "$fixture/.chump/state.db" \
    "SELECT status FROM gaps WHERE id='$test_id'" 2>/dev/null)
if [[ "$db_status" == "open" ]]; then
    pass "DB row unchanged after rejected write (still status=open)"
else
    fail "DB row was mutated despite the guard (status=$db_status)"
fi

# 3. With --closed-pr, status=done succeeds.
out=$($CHUMP gap set "$test_id" --status done --closed-pr 9999 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "status=done WITH --closed-pr 9999 succeeds"
else
    fail "status=done with --closed-pr should succeed (rc=$rc)"
fi

# 4. Bypass env honored (for genuine migration cases).
test_id2=$(sqlite3 "$fixture/.chump/state.db" \
    "SELECT id FROM gaps WHERE status='open' ORDER BY id LIMIT 1 OFFSET 1" 2>/dev/null)
if [[ -n "$test_id2" ]]; then
    out=$(CHUMP_BYPASS_CLOSED_PR_GUARD=1 $CHUMP gap set "$test_id2" --status done 2>&1) && rc=$? || rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "CHUMP_BYPASS_CLOSED_PR_GUARD=1 honored"
    else
        fail "bypass env should allow status=done without closed_pr (rc=$rc)"
    fi
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
