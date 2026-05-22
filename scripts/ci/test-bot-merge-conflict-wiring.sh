#!/usr/bin/env bash
# scripts/ci/test-bot-merge-conflict-wiring.sh — INFRA-1657
#
# Source-contract test: verify that bot-merge.sh wires the
# conflict-resolver-agent (INFRA-1488) into its rebase-failure path.
#
# This is a static-source test (not a runtime test) for three reasons:
#   1. bot-merge.sh's rebase phase is hundreds of lines deep into a script
#      with extensive side-effects (gh API calls, ambient.jsonl writes,
#      lease management); a runtime fixture would dwarf the actual change.
#   2. The conflict-resolver-agent itself is already covered by a runtime
#      test (scripts/ci/test-conflict-resolver.sh, INFRA-1488 AC#6).
#   3. What this PR is wiring is a syntactic call site — the contract is
#      "bot-merge invokes conflict-resolver-agent inside the rebase-failure
#      branch, gated on the same env flag". Source inspection is the right
#      assertion shape.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
AGENT="$REPO_ROOT/scripts/coord/conflict-resolver-agent.sh"

fail=0
note() { printf '[test-bot-merge-conflict-wiring] %s\n' "$*"; }
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }

note "checking $BOT_MERGE"

# Sanity: the files we depend on exist.
[[ -f "$BOT_MERGE" ]] || { bad "bot-merge.sh missing at $BOT_MERGE"; exit 1; }
[[ -f "$AGENT"     ]] || { bad "conflict-resolver-agent.sh missing at $AGENT"; exit 1; }
ok "both source files present"

# Contract 1: bot-merge.sh references conflict-resolver-agent.sh.
if grep -q 'conflict-resolver-agent\.sh' "$BOT_MERGE"; then
    ok "bot-merge.sh references conflict-resolver-agent.sh"
else
    bad "bot-merge.sh does NOT reference conflict-resolver-agent.sh"
fi

# Contract 2: the reference is inside (or directly bound to) the
# rebase-failure branch. We confirm by checking that the call appears in
# the same range as 'git rebase' AND 'rebase failed', and BEFORE the
# `_bm_fail "rebase"` exit.
rebase_failed_ln="$(grep -n 'git rebase failed or timed out' "$BOT_MERGE" | head -1 | cut -d: -f1)"
bm_fail_rebase_ln="$(grep -n '_bm_fail "rebase"' "$BOT_MERGE" | head -1 | cut -d: -f1)"
agent_call_ln="$(grep -n 'conflict-resolver-agent\.sh' "$BOT_MERGE" | head -1 | cut -d: -f1)"

if [[ -n "$rebase_failed_ln" && -n "$bm_fail_rebase_ln" && -n "$agent_call_ln" ]]; then
    if (( agent_call_ln > rebase_failed_ln && agent_call_ln <= bm_fail_rebase_ln + 5 )); then
        ok "conflict-resolver-agent call sits inside rebase-failure branch (lines $rebase_failed_ln < $agent_call_ln ≈ $bm_fail_rebase_ln)"
    else
        bad "conflict-resolver-agent call is OUTSIDE rebase-failure branch (rebase_failed=$rebase_failed_ln agent_call=$agent_call_ln bm_fail=$bm_fail_rebase_ln)"
    fi
else
    bad "could not locate all anchors (rebase_failed=$rebase_failed_ln bm_fail=$bm_fail_rebase_ln agent_call=$agent_call_ln)"
fi

# Contract 3: the wiring path acknowledges the feature flag — either
# directly in bot-merge.sh, OR by deferring to the agent's own gate
# (which is the chosen pattern). We accept either:
#   (a) bot-merge.sh references CHUMP_CONFLICT_RESOLVER_ENABLED in the
#       rebase-failure context, OR
#   (b) the agent script itself contains the gate (and bot-merge defers).
if grep -q 'CHUMP_CONFLICT_RESOLVER_ENABLED' "$BOT_MERGE"; then
    ok "bot-merge.sh references CHUMP_CONFLICT_RESOLVER_ENABLED directly"
elif grep -q 'CHUMP_CONFLICT_RESOLVER_ENABLED' "$AGENT"; then
    ok "agent script self-gates on CHUMP_CONFLICT_RESOLVER_ENABLED (bot-merge defers)"
else
    bad "neither bot-merge.sh nor conflict-resolver-agent.sh references CHUMP_CONFLICT_RESOLVER_ENABLED"
fi

# Contract 4: rebase --abort is called on agent-handoff (exit != 0).
# This protects against leaving the worktree in a mid-rebase state.
if grep -q 'git rebase --abort' "$BOT_MERGE"; then
    ok "bot-merge.sh contains git rebase --abort handoff path"
else
    bad "bot-merge.sh missing git rebase --abort handoff path"
fi

# Contract 5: syntax check still passes.
if bash -n "$BOT_MERGE"; then
    ok "bot-merge.sh syntax OK (bash -n)"
else
    bad "bot-merge.sh syntax error (bash -n failed)"
fi

if (( fail > 0 )); then
    note "FAIL: $fail contract violation(s)"
    exit 1
fi
note "OK"
exit 0
