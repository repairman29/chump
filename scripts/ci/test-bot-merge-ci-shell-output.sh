#!/usr/bin/env bash
# test-bot-merge-ci-shell-output.sh — INFRA-473
#
# Verifies bot-merge.sh's CI shell test runner preserves enough output
# of a failed test to diagnose WHICH assertion failed without re-running
# locally. Pre-INFRA-473 the runner did `tail -10` of a single shared
# log file — for tests that print verbose output then a "N passed M
# failed" summary, the actual FAIL line was often truncated out.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"

[[ -f "$SCRIPT" ]] || { echo "FATAL: bot-merge.sh missing"; exit 2; }

echo "=== INFRA-473 bot-merge CI shell output diagnostics test ==="
echo

# --- Test 1: per-test log paths (not a single shared one) ---
if grep -qE 'ci_log="/tmp/bot-merge-citest-' "$SCRIPT"; then
    ok "per-test log path used (not a single shared file)"
else
    fail "still using a single shared /tmp/bot-merge-citest.log path"
fi

# --- Test 2: surfaces explicit FAIL: lines from the test output ---
if grep -qE "grep -E '\^\\\\s\*FAIL:'" "$SCRIPT"; then
    ok "extracts explicit FAIL: lines from the test log"
else
    fail "doesn't surface FAIL: lines"
fi

# --- Test 3: prints last-30 (not last-10) for context ---
if grep -qE '^\s*tail -30 "\$ci_log"' "$SCRIPT"; then
    ok "shows last 30 lines for context (was 10 — too short for verbose tests)"
else
    fail "still using tail -10"
fi

# --- Test 4: tells the user where to find the full log ---
if grep -q 'full log: \$ci_log' "$SCRIPT" \
   && grep -q 'Full per-test logs at /tmp/bot-merge-citest-' "$SCRIPT"; then
    ok "points operator to the full per-test log file"
else
    fail "no pointer to full log path"
fi

# --- Test 5: total-line count is shown so the operator knows if 30 was a sample ---
if grep -q 'wc -l <"\$ci_log"' "$SCRIPT"; then
    ok "shows total-line count alongside the tail sample"
else
    fail "no total-line count — operator can't tell if tail was complete"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
