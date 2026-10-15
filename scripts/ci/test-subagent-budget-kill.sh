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

# ---- 6. Default is 1800s (RESILIENT-1494 operator ruling; matches CLAUDE.md) ----
# The default lives in DEFAULT_SUBAGENT_BUDGET_SECS and is used via
# .unwrap_or(DEFAULT_SUBAGENT_BUDGET_SECS) on the budget chain.
if grep -q 'const DEFAULT_SUBAGENT_BUDGET_SECS: u64 = 1800' "$SRC" \
    || grep -A2 'CHUMP_SUBAGENT_BUDGET_S' "$SRC" | grep -q 'unwrap_or(1800)'; then
    pass "src/dispatch.rs default budget = 1800s"
else
    # Less strict — allow it on a nearby line
    if grep -B5 -A20 'CHUMP_SUBAGENT_BUDGET_S' "$SRC" | grep -q 'unwrap_or(1800)'; then
        pass "src/dispatch.rs default budget = 1800s (within budget block)"
    else
        fail "src/dispatch.rs default budget should be 1800 (matching CLAUDE.md)"
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
