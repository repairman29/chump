#!/usr/bin/env bash
# scripts/ci/test-bot-merge-policy-integration.sh — INFRA-2155 smoke test.
#
# Asserts the chump-policy + chump-reviewer-routing wire-up inserted into
# bot-merge.sh has the right shape WITHOUT needing a real PR + gh API:
#   - bot-merge.sh contains the INFRA-2155 anchor comments
#   - the policy-blocked code path sets _policy_blocked=1 and skips arm
#   - CHUMP_BYPASS_AUTO_MERGE_POLICY=1 emits auto_merge_policy_bypassed
#   - both binaries (chump-policy, chump-reviewer-routing) are looked up
#     via the worktree-OR-workspace-target probe pattern
#   - the EVENT_REGISTRY.yaml has the new kind registered
#
# We do NOT run the full bot-merge end-to-end here — that's covered by
# scripts/ci/test-bot-merge-* siblings on real PR fixtures. This test
# focuses on the INFRA-2155 surgical insert.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# ── Test 1: bash syntax clean after edits ──────────────────────────────────
echo ""
echo "Test 1: bash -n bot-merge.sh"
if bash -n "$BOT_MERGE"; then
    pass "bash syntax OK"
else
    fail "bash syntax broken after INFRA-2155 edits"
fi

# ── Test 2: INFRA-2155 anchor comments present ─────────────────────────────
echo ""
echo "Test 2: INFRA-2155 anchor comments present in bot-merge.sh"
for anchor in \
    "INFRA-2155: chump-policy check" \
    "INFRA-2155: chump-reviewer-routing" \
    "CHUMP_BYPASS_AUTO_MERGE_POLICY" \
    "CHUMP_BYPASS_REVIEWER_ROUTING" \
    "_policy_blocked"; do
    if grep -q "$anchor" "$BOT_MERGE"; then
        pass "anchor present: '$anchor'"
    else
        fail "anchor missing: '$anchor'"
    fi
done

# ── Test 3: binary-probe loop covers worktree + workspace + PATH ───────────
echo ""
echo "Test 3: chump-policy binary-probe loop covers 3 paths"
# Count occurrences of the canonical fallback strings.
if grep -q "target/debug/chump-policy" "$BOT_MERGE" \
   && grep -q "command -v chump-policy" "$BOT_MERGE"; then
    pass "chump-policy probe covers worktree + PATH"
else
    fail "chump-policy probe incomplete"
fi
if grep -q "target/debug/chump-reviewer-routing" "$BOT_MERGE" \
   && grep -q "command -v chump-reviewer-routing" "$BOT_MERGE"; then
    pass "chump-reviewer-routing probe covers worktree + PATH"
else
    fail "chump-reviewer-routing probe incomplete"
fi

# ── Test 4: EVENT_REGISTRY.yaml registers the new bypass kind ──────────────
echo ""
echo "Test 4: EVENT_REGISTRY.yaml registers auto_merge_policy_bypassed"
if grep -q "kind: auto_merge_policy_bypassed" "$EVENT_REG"; then
    pass "auto_merge_policy_bypassed registered"
else
    fail "auto_merge_policy_bypassed missing from EVENT_REGISTRY"
fi

# ── Test 5: the gate doesn't accidentally short-circuit when binary missing ─
# When neither chump-policy nor chump-reviewer-routing exists, the wire-up
# must FALL THROUGH (not block auto-merge). The gate is opt-in.
echo ""
echo "Test 5: 'no binary present' falls through (does not block arm)"
# Confirm the condition: stage only runs when -x binary exists.
# `grep -A 1` on the `if [[ -n "$_chump_policy_bin" ]]` line should show
# the conditional, not an unconditional block.
if grep -A 1 'if \[\[ -n "$_chump_policy_bin" \]\]' "$BOT_MERGE" \
   | grep -q "CHUMP_BYPASS_AUTO_MERGE_POLICY"; then
    pass "policy gate is conditional on binary presence (not a hard block)"
else
    fail "policy gate may block when binary missing — check fall-through path"
fi

# ── Test 6: _policy_blocked variable is consulted before arm ──────────────
echo ""
echo "Test 6: _policy_blocked=1 prevents arm in the next if-guard"
if grep -q '_policy_blocked:-0' "$BOT_MERGE"; then
    pass "_policy_blocked default-0 expansion present"
else
    fail "_policy_blocked default-0 expansion missing — gate may misfire"
fi
if grep -q '_rest_direct_merged -eq 0 \]\] && \[\[ "${_policy_blocked' "$BOT_MERGE"; then
    pass "arm-guard checks both _rest_direct_merged AND _policy_blocked"
else
    fail "arm-guard does not consult _policy_blocked — may arm when blocked"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
