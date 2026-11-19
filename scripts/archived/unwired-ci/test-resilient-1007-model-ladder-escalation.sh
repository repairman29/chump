#!/usr/bin/env bash
# scripts/ci/test-resilient-1007-model-ladder-escalation.sh — RESILIENT-1007
# (RESILIENT-596 slice)
#
# Verifies the model-capability rc=1 escalation added to scripts/dispatch/worker.sh:
# when a chump-local cycle exits rc=1 with a genuine model-capability-failure
# signature (this rung can't handle the tool-call shape), the worker must
# escalate to the next CHUMP_MODEL_ESCALATION_LADDER rung instead of cooling
# down / auto-blocking the gap as if it were a bad gap.
#
#   1. classify_model_capability_failure() detects tool-capability signatures
#   2. classify_model_capability_failure() returns "none" for an unrelated failure
#   3. worker.sh emits kind=model_ladder_capability_escalation
#   4. worker.sh skips cooldown-writing for capability-classified failures
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

# Extract just the classify_model_capability_failure() function body and
# source it in isolation — worker.sh as a whole has launch-time side effects
# (heartbeat daemon, trap installation) that make it unsafe to source wholesale
# in a test.
_fn_tmp="$(mktemp)"
_logdir="$(mktemp -d)"
trap 'rm -f "$_fn_tmp"; rm -rf "$_logdir"' EXIT
awk '/^classify_model_capability_failure\(\)/,/^}/' "$WORKER_SH" > "$_fn_tmp"
if [[ ! -s "$_fn_tmp" ]]; then
    fail "could not extract classify_model_capability_failure() from worker.sh — aborting"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
# shellcheck disable=SC1090
source "$_fn_tmp"

# ── Test 1: tool-capability signatures ──────────────────────────────────────
echo 'API Error: 400 {"error":{"message":"UnsupportedToolUse: model does not support more than one tool call at this time"}}' > "$_logdir/cap1.log"
_class="$(classify_model_capability_failure "$_logdir/cap1.log")"
if [[ "$_class" == "tool-capability" ]]; then
    ok "Test 1a: UnsupportedToolUse classified as tool-capability"
else
    fail "Test 1a: expected tool-capability, got '$_class'"
fi

echo '{"error":{"message":"Function calling config is set without function_declarations"}}' > "$_logdir/cap2.log"
_class="$(classify_model_capability_failure "$_logdir/cap2.log")"
if [[ "$_class" == "tool-capability" ]]; then
    ok "Test 1b: Gemini function_declarations message classified as tool-capability"
else
    fail "Test 1b: expected tool-capability, got '$_class'"
fi

# ── Test 2: unrelated failure → none (do NOT skip cooldown) ─────────────────
echo 'error: could not find file src/main.rs; compilation failed' > "$_logdir/other.log"
_class="$(classify_model_capability_failure "$_logdir/other.log")"
if [[ "$_class" == "none" ]]; then
    ok "Test 2: unrelated compile failure classified as none"
else
    fail "Test 2: expected none, got '$_class'"
fi

# ── Test 3: escalation ambient event present in worker.sh ───────────────────
if grep -q '"kind":"model_ladder_capability_escalation"' "$WORKER_SH"; then
    ok "Test 3: worker.sh emits kind=model_ladder_capability_escalation"
else
    fail "Test 3: kind=model_ladder_capability_escalation missing from worker.sh"
fi

# ── Test 4: cooldown write is guarded by _capability_escalation_fail ────────
if grep -q '_capability_escalation_fail:-0' "$WORKER_SH"; then
    ok "Test 4: cooldown block guards on _capability_escalation_fail (never blocks a gap for a capability escalation)"
else
    fail "Test 4: cooldown block does not guard on _capability_escalation_fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
