#!/usr/bin/env bash
# test-gemini-thinking-budget.sh — INFRA-790
#
# CI gate: Gemini "thinking" blocks must never reach the agent loop / user
# surfaces raw, and GEMINI_THINKING_BUDGET_TOKENS must be honored (default 0 =
# strip/disable all thinking).
#
#   1. A fixture Gemini response containing a <think>...</think> block is
#      stripped clean (no <think> markers survive).
#   2. GEMINI_THINKING_BUDGET_TOKENS defaults to 0 and is honored when set.
#   3. A plain Gemini response with no thinking block is unaffected
#      (no regression on normal gemini-2.5-flash / 2.5-pro responses).
#
# Exit codes:
#   0 — all checks passed
#   1 — a check failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
ok()   { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }

echo "=== INFRA-790 Gemini thinking-token budget CI validation ==="
echo

echo "--- 1. thinking blocks stripped before agent loop sees them ---"
if cargo test -p chump --lib thinking_strip::tests::strips_gemini_thinking_block_from_response -- --nocapture 2>&1 | tee /tmp/infra790-strip.log | grep -q "test result: ok"; then
    ok "gemini <think> block stripped clean"
else
    fail "gemini <think> block stripping test failed (see /tmp/infra790-strip.log)"
fi

echo
echo "--- 2. GEMINI_THINKING_BUDGET_TOKENS honored (default 0 / custom value) ---"
if cargo test -p chump --lib reasoning_mode::tests::gemini_thinking_budget -- --nocapture 2>&1 | tee /tmp/infra790-budget.log | grep -q "test result: ok"; then
    ok "GEMINI_THINKING_BUDGET_TOKENS default + override honored"
else
    fail "GEMINI_THINKING_BUDGET_TOKENS test failed (see /tmp/infra790-budget.log)"
fi

echo
echo "--- 3. no regression on plain gemini-2.5-flash/pro responses ---"
if cargo test -p chump --lib thinking_strip::tests::no_regression_on_plain_gemini_response_without_thinking -- --nocapture 2>&1 | tee /tmp/infra790-noregress.log | grep -q "test result: ok"; then
    ok "plain gemini response passes through unchanged"
else
    fail "no-regression test failed (see /tmp/infra790-noregress.log)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo "=== FAILURES DETECTED ===" >&2
    exit 1
fi
