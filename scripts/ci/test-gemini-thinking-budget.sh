#!/usr/bin/env bash
# INFRA-790 — Gemini thinking-token budget: strip or budget for think blocks
# in the agent loop.
#
# Strategy: the actual logic + fixtures live as Rust unit tests in
# src/local_openai.rs (LocalOpenAIProvider is where Gemini is dispatched via
# its OpenAI-compatible endpoint). This script runs just that test slice so
# CI/preflight has a single named gate to point at:
#   - gemini_request_defaults_thinking_budget_to_zero   (AC2: default budget 0)
#   - gemini_request_honors_thinking_budget_override    (AC2: GEMINI_THINKING_BUDGET_TOKENS)
#   - gemini_response_with_think_block_is_stripped_before_agent_loop (AC1/AC3/AC4:
#       fixture response with <think> blocks -> assert output contains no <think> markers)
#   - gemini_thinking_budget_clamped_to_max              (bounds sanity)
#   - complete_parses_valid_response_and_tool_calls       (AC5: no regression on
#       a normal response without thinking blocks)

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v cargo >/dev/null 2>&1; then
    fail "cargo not on PATH"
    exit 1
fi

set +e
OUT="$(cargo test -p chump --bin chump local_openai::tests::gemini -- --test-threads=1 2>&1)"
STATUS=$?
OUT2="$(cargo test -p chump --bin chump local_openai::tests::complete_parses_valid_response_and_tool_calls -- --test-threads=1 2>&1)"
STATUS2=$?
set -e

echo "$OUT"
echo "$OUT2"
OUT="$OUT
$OUT2"

if [[ $STATUS -ne 0 || $STATUS2 -ne 0 ]]; then
    fail "cargo test exited non-zero"
else
    pass "cargo test exited 0"
fi

if echo "$OUT" | grep -q "gemini_request_defaults_thinking_budget_to_zero ... ok"; then
    pass "default thinking budget is 0 (thinking stripped by default)"
else
    fail "default thinking budget test did not pass"
fi

if echo "$OUT" | grep -q "gemini_request_honors_thinking_budget_override ... ok"; then
    pass "GEMINI_THINKING_BUDGET_TOKENS override honored in request"
else
    fail "thinking budget override test did not pass"
fi

if echo "$OUT" | grep -q "gemini_response_with_think_block_is_stripped_before_agent_loop ... ok"; then
    pass "fixture response with <think> blocks stripped before agent loop"
else
    fail "think-block stripping test did not pass"
fi

if echo "$OUT" | grep -q "complete_parses_valid_response_and_tool_calls ... ok"; then
    pass "no regression on normal responses without thinking blocks"
else
    fail "normal-response regression test did not pass"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
