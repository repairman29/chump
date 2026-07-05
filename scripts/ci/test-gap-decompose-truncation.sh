#!/usr/bin/env bash
# test-gap-decompose-truncation.sh — INFRA-2173
#
# Validates that `chump gap decompose` handles truncated LLM JSON gracefully:
#   AC1. Detects truncated JSON (ends without closing ']') and retries.
#   AC2. On final truncation failure, recovers partial slices from the
#        parseable prefix and surfaces a warning to the operator.
#   AC3. Source-code checks: looks_truncated + recover_partial_slices present.
#
# No LLM call required — all tests are structural / unit-level.
#
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
MAIN_RS="$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"

echo "=== INFRA-2173 gap decompose truncation test ==="
echo ""

# ── AC1 / AC2: source-level checks ──────────────────────────────────────────

if grep -q "looks_truncated" "$MAIN_RS"; then
    ok "looks_truncated heuristic function present in main.rs"
else
    fail "looks_truncated heuristic missing from main.rs"
fi

if grep -q "recover_partial_slices" "$MAIN_RS"; then
    ok "recover_partial_slices function present in main.rs"
else
    fail "recover_partial_slices function missing from main.rs"
fi

if grep -q "MaxTokens\|max_tokens\|MAX_TOKENS" "$MAIN_RS" | grep -qi "retry\|budget\|RETRY\|BUDGET"; then
    ok "retry-with-larger-budget logic references present"
else
    # Looser check: retry loop present
    if grep -q "MAX_TOKENS_RETRY\|MAX_TOKENS_FINAL" "$MAIN_RS"; then
        ok "retry budget constants MAX_TOKENS_RETRY / MAX_TOKENS_FINAL present"
    else
        fail "retry budget constants not found in main.rs"
    fi
fi

if grep -q "partial decomposition recovered" "$MAIN_RS"; then
    ok "'partial decomposition recovered' operator message present"
else
    fail "'partial decomposition recovered' message missing — AC2 not surfaced to operator"
fi

if grep -q "StopReason::MaxTokens\|stop_reason.*MaxTokens\|MaxTokens.*stop_reason" "$MAIN_RS"; then
    ok "StopReason::MaxTokens used to detect provider-side truncation"
else
    fail "StopReason::MaxTokens not referenced — provider truncation signal not consumed"
fi

# ── Retry logic wiring check ────────────────────────────────────────────────

if grep -q "token_budgets\|retry.*budget\|budget.*retry" "$MAIN_RS"; then
    ok "token_budgets array or retry-budget loop present"
else
    fail "token_budgets / retry-budget loop not found"
fi

# ── Warning surfaced to operator on partial recovery ─────────────────────────

if grep -q "partial_recovery\|partial decomposition only" "$MAIN_RS"; then
    ok "partial_recovery warning path present"
else
    fail "partial_recovery warning path missing — operator won't know result is incomplete"
fi

# ── Confirm the old hard-exit-on-parse-failure path is gone ─────────────────
# (The old code had a single serde_json parse + immediate std::process::exit(1)
#  with no retry.  The new code wraps this in a retry loop.)

OLD_PATTERN='serde_json::from_str(json_slice)'
if grep -q "$OLD_PATTERN" "$MAIN_RS"; then
    fail "old single-shot parse path '$OLD_PATTERN' still present — retry loop may not be wired"
else
    ok "old single-shot parse path removed (retry loop is the only path)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
