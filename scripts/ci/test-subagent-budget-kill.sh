#!/usr/bin/env bash
# test-subagent-budget-kill.sh — INFRA-1972 (H3) structural regression test.
#
# Verifies the parent-enforced subagent budget mechanism is in place:
#   - CHUMP_SUBAGENT_BUDGET_S env var is read by wait_with_hang_detection
#   - kind=subagent_killed_at_budget is emitted (not just kind=hang_detector)
#   - SIGTERM is sent at budget (Command::new("kill") with -TERM)
#   - SIGKILL after grace via child.kill() (existing path)
#   - EVENT_REGISTRY.yaml has the new kind registered
#
# This is a STRUCTURAL test (lints source for the right pieces) rather
# than a runtime test. Runtime behavior validation is a separate manual
# smoke pending a Rust unit-test follow-up gap.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

fail() {
    echo "[FAIL] $1" >&2
    exit 1
}

pass() {
    echo "[PASS] $1"
}

SRC="src/dispatch.rs"
REG="docs/observability/EVENT_REGISTRY.yaml"

# ---- 1. Source has the new env var ----
if grep -q 'CHUMP_SUBAGENT_BUDGET_S' "$SRC"; then
    pass "src/dispatch.rs reads CHUMP_SUBAGENT_BUDGET_S"
else
    fail "src/dispatch.rs missing CHUMP_SUBAGENT_BUDGET_S env-var read"
fi

# ---- 2. Source emits the new event kind ----
if grep -q 'subagent_killed_at_budget' "$SRC"; then
    pass "src/dispatch.rs emits kind=subagent_killed_at_budget"
else
    fail "src/dispatch.rs missing subagent_killed_at_budget emit"
fi

# ---- 3. Source has the SIGTERM call (Command::new("kill") with -TERM) ----
if grep -q '"-TERM"' "$SRC" && grep -q 'Command::new("kill")' "$SRC"; then
    pass "src/dispatch.rs sends SIGTERM via Command::new(\"kill\") with -TERM arg"
else
    fail "src/dispatch.rs missing graceful SIGTERM call"
fi

# ---- 4. Source has the SIGKILL fallback after grace ----
# Grace is implemented as "if budget_kill_in_flight elapsed > grace_secs → child.kill()"
if grep -q 'grace_secs' "$SRC" && grep -q 'budget_kill_in_flight' "$SRC"; then
    pass "src/dispatch.rs has SIGTERM→SIGKILL grace window logic"
else
    fail "src/dispatch.rs missing grace-window enforcement"
fi

# ---- 5. Source falls back to legacy CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S ----
# Preserves existing CLAUDE.md env-var configs.
if grep -q 'CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S' "$SRC"; then
    pass "src/dispatch.rs falls back to legacy CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S"
else
    fail "src/dispatch.rs missing legacy env-var fallback"
fi

# ---- 6. Default is 900s (matching CLAUDE.md self-discipline rule) ----
# Look for .unwrap_or(900) on the budget chain.
if grep -A2 'CHUMP_SUBAGENT_BUDGET_S' "$SRC" | grep -q 'unwrap_or(900)'; then
    pass "src/dispatch.rs default budget = 900s"
else
    # Less strict — allow it on a nearby line
    if grep -B5 -A20 'CHUMP_SUBAGENT_BUDGET_S' "$SRC" | grep -q 'unwrap_or(900)'; then
        pass "src/dispatch.rs default budget = 900s (within budget block)"
    else
        fail "src/dispatch.rs default budget should be 900 (matching CLAUDE.md)"
    fi
fi

# ---- 7. EVENT_REGISTRY has the new kind ----
if grep -q 'kind: subagent_killed_at_budget' "$REG"; then
    pass "EVENT_REGISTRY.yaml has subagent_killed_at_budget kind"
else
    fail "EVENT_REGISTRY.yaml missing subagent_killed_at_budget kind"
fi

# ---- 8. Registry entry has the required fields list ----
if grep -A8 'kind: subagent_killed_at_budget' "$REG" | grep -q 'fields_required'; then
    pass "EVENT_REGISTRY.yaml lists required fields for subagent_killed_at_budget"
else
    fail "EVENT_REGISTRY.yaml missing fields_required for subagent_killed_at_budget"
fi

echo
echo "[OK] all 8 INFRA-1972 structural cases passed"

# ── INFRA-2090: token + dollar budget extension ──────────────────────────────
# Extends the INFRA-1972 parent-kill mechanism from wall-clock-only to a
# live streaming-token counter (CHUMP_SUBAGENT_TOKEN_BUDGET) and a
# per-model-rate-card dollar figure (CHUMP_SUBAGENT_DOLLAR_BUDGET).

# ---- 9. Source reads both new budget env vars ----
if grep -q 'CHUMP_SUBAGENT_TOKEN_BUDGET' "$SRC"; then
    pass "src/dispatch.rs reads CHUMP_SUBAGENT_TOKEN_BUDGET"
else
    fail "src/dispatch.rs missing CHUMP_SUBAGENT_TOKEN_BUDGET env-var read"
fi

if grep -q 'CHUMP_SUBAGENT_DOLLAR_BUDGET' "$SRC"; then
    pass "src/dispatch.rs reads CHUMP_SUBAGENT_DOLLAR_BUDGET"
else
    fail "src/dispatch.rs missing CHUMP_SUBAGENT_DOLLAR_BUDGET env-var read"
fi

# ---- 10. Source emits the two new event kinds ----
if grep -q 'subagent_killed_at_token_budget' "$SRC"; then
    pass "src/dispatch.rs emits kind=subagent_killed_at_token_budget"
else
    fail "src/dispatch.rs missing subagent_killed_at_token_budget emit"
fi

if grep -q 'subagent_killed_at_dollar_budget' "$SRC"; then
    pass "src/dispatch.rs emits kind=subagent_killed_at_dollar_budget"
else
    fail "src/dispatch.rs missing subagent_killed_at_dollar_budget emit"
fi

# ---- 11. Dollar budget is priced via the shared per-model rate card ----
if grep -q 'session_ledger::cost_usd_from_tokens' "$SRC"; then
    pass "src/dispatch.rs prices the dollar budget via session_ledger::cost_usd_from_tokens (shared rate card)"
else
    fail "src/dispatch.rs missing per-model rate-card cost lookup"
fi

# ---- 12. Live usage is fed from a streaming source, not a post-hoc log scan ----
if grep -q 'output-format' "$SRC" && grep -q 'stream-json' "$SRC"; then
    pass "src/dispatch.rs requests --output-format stream-json to observe live usage"
else
    fail "src/dispatch.rs missing --output-format stream-json wiring for live usage"
fi

# ---- 13. EVENT_REGISTRY has both new kinds ----
if grep -q 'kind: subagent_killed_at_token_budget' "$REG"; then
    pass "EVENT_REGISTRY.yaml has subagent_killed_at_token_budget kind"
else
    fail "EVENT_REGISTRY.yaml missing subagent_killed_at_token_budget kind"
fi

if grep -q 'kind: subagent_killed_at_dollar_budget' "$REG"; then
    pass "EVENT_REGISTRY.yaml has subagent_killed_at_dollar_budget kind"
else
    fail "EVENT_REGISTRY.yaml missing subagent_killed_at_dollar_budget kind"
fi

# ---- 14. Registry entries have required fields lists ----
if grep -A10 'kind: subagent_killed_at_token_budget' "$REG" | grep -q 'fields_required'; then
    pass "EVENT_REGISTRY.yaml lists required fields for subagent_killed_at_token_budget"
else
    fail "EVENT_REGISTRY.yaml missing fields_required for subagent_killed_at_token_budget"
fi

if grep -A10 'kind: subagent_killed_at_dollar_budget' "$REG" | grep -q 'fields_required'; then
    pass "EVENT_REGISTRY.yaml lists required fields for subagent_killed_at_dollar_budget"
else
    fail "EVENT_REGISTRY.yaml missing fields_required for subagent_killed_at_dollar_budget"
fi

echo
echo "[OK] all 6 INFRA-2090 structural cases passed"
