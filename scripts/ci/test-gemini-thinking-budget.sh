#!/usr/bin/env bash
# scripts/ci/test-gemini-thinking-budget.sh — INFRA-790
#
# Validates the Gemini thinking-token budget/strip contract:
#   1. src/thinking_strip.rs strips <think>...</think> blocks (Gemini uses the
#      same tag shape as Qwen3) before the agent loop stores conversation
#      history — a fixture response with a think block must yield output with
#      no <think> markers.
#   2. src/reasoning_mode.rs honors GEMINI_THINKING_BUDGET_TOKENS (default 0 =
#      strip all / disable thinking) when building the Gemini API request
#      params, with includeThoughts following the budget.
#   3. No regression: normal Gemini responses without think blocks pass
#      through untouched.
#
# Run from repo root: bash scripts/ci/test-gemini-thinking-budget.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-790 Gemini thinking-budget tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 1

CARGO_BIN="${CARGO:-cargo}"
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then
    for cand in "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo /opt/homebrew/bin/cargo; do
        [[ -x "$cand" ]] && CARGO_BIN="$cand" && break
    done
fi

# ── (0) source-contract: expected surfaces exist ──
THINK_MOD="$REPO_ROOT/src/thinking_strip.rs"
REASONING_MOD="$REPO_ROOT/src/reasoning_mode.rs"

[[ -f "$THINK_MOD" ]] && ok "thinking_strip.rs exists" || { fail "missing $THINK_MOD"; exit 1; }
[[ -f "$REASONING_MOD" ]] && ok "reasoning_mode.rs exists" || { fail "missing $REASONING_MOD"; exit 1; }

grep -qF "pub fn strip_for_public_reply" "$THINK_MOD" \
    && ok "strip_for_public_reply defined" \
    || fail "strip_for_public_reply missing"

grep -qF "GEMINI_THINKING_BUDGET_TOKENS" "$REASONING_MOD" \
    && ok "GEMINI_THINKING_BUDGET_TOKENS wired into reasoning_mode.rs" \
    || fail "GEMINI_THINKING_BUDGET_TOKENS not referenced in reasoning_mode.rs"

# ── (1) cargo unit tests: strip <think> blocks (AC1, AC3, AC4) ──
echo "--- running cargo test --bin chump thinking_strip::tests ---"
if "$CARGO_BIN" test --bin chump --quiet thinking_strip::tests 2>&1 | tee /tmp/gemini-thinking-strip-out.txt \
        | grep -qE "test result: ok"; then
    ok "cargo unit tests pass for thinking_strip"
else
    fail "cargo unit tests failed (run: cargo test --bin chump thinking_strip::tests)"
fi

if grep -q "gemini_think_block_stripped_before_agent_loop_sees_it" /tmp/gemini-thinking-strip-out.txt; then
    ok "gemini-specific fixture test ran"
else
    fail "gemini-specific fixture test did not run"
fi

# Fixture assertion in bash terms too (belt-and-suspenders on the AC wording):
# a fixture response containing <think> blocks, once run through the same
# stripping logic exercised by the Rust test above, must contain no <think>
# markers. We assert this indirectly via the dedicated Rust test passing
# (checked above) plus a static check that the test asserts the no-marker
# invariant.
if grep -A6 "fn gemini_think_block_stripped_before_agent_loop_sees_it" "$THINK_MOD" \
    | grep -q '!cleaned.contains("<think>")'; then
    ok "fixture test asserts no <think> marker survives stripping"
else
    fail "fixture test missing no-<think>-marker assertion"
fi

# ── (2) cargo unit tests: GEMINI_THINKING_BUDGET_TOKENS honored (AC2) ──
echo "--- running cargo test --bin chump reasoning_mode::tests::build_gemini ---"
if "$CARGO_BIN" test --bin chump --quiet reasoning_mode::tests::build_gemini 2>&1 \
        | tee /tmp/gemini-thinking-budget-out.txt | grep -qE "test result: ok"; then
    ok "cargo unit tests pass for reasoning_mode Gemini budget params"
else
    fail "cargo unit tests failed (run: cargo test --bin chump reasoning_mode::tests::build_gemini)"
fi

for t in \
    build_gemini_params_default_budget_is_zero \
    build_gemini_params_honors_gemini_specific_budget \
    build_gemini_params_falls_back_to_shared_reasoning_budget \
    build_gemini_params_gemini_specific_takes_precedence; do
    if grep -q "$t" /tmp/gemini-thinking-budget-out.txt; then
        ok "budget test ran: $t"
    else
        fail "budget test did not run: $t"
    fi
done

# ── (3) no regression: normal Gemini responses without think blocks (AC5) ──
echo "--- running cargo test --bin chump reasoning_mode::tests::model_supports_reasoning_gemini_thinking ---"
if "$CARGO_BIN" test --bin chump --quiet reasoning_mode::tests::model_supports_reasoning_gemini_thinking 2>&1 \
        | grep -qE "test result: ok"; then
    ok "normal gemini-2.5-pro / gemini-2.5-flash-thinking detection unaffected"
else
    fail "reasoning-model detection regressed for normal Gemini responses"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
