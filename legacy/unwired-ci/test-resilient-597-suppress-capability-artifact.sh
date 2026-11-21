#!/usr/bin/env bash
# scripts/ci/test-resilient-597-suppress-capability-artifact.sh — RESILIENT-597
# (RESILIENT-596 slice)
#
# Verifies the artifact-suppression addition to the RESILIENT-1007
# model-capability escalation path in scripts/dispatch/worker.sh: a
# capability-failed attempt (rc=1, tool-capability signature) must not let
# any PR it opened merge or count as a ship — the worker closes it and emits
# a loud ambient event, then escalates to the next CHUMP_MODEL_ESCALATION_LADDER
# rung as before (RESILIENT-1007 already covers escalation + cooldown skip).
#
#   1. worker.sh closes any open PR on this gap's branch when a capability
#      failure is detected (gh pr close call present, gated on _cap_pr)
#   2. worker.sh emits kind=model_ladder_artifact_suppressed
#   3. the suppression block is nested inside the same capability-failure
#      branch that already skips cooldown/auto-block (RESILIENT-1007) — so
#      escalation still fires unchanged
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

# ── Test 1: PR-close call present, gated on a resolved PR number ───────────
if grep -q 'gh pr close "\$_cap_pr"' "$WORKER_SH"; then
    ok "Test 1: worker.sh closes the open PR for the failed attempt's branch"
else
    fail "Test 1: gh pr close \"\$_cap_pr\" missing from worker.sh"
fi

# ── Test 2: loud ambient event naming the suppression ──────────────────────
if grep -q '"kind":"model_ladder_artifact_suppressed"' "$WORKER_SH"; then
    ok "Test 2: worker.sh emits kind=model_ladder_artifact_suppressed"
else
    fail "Test 2: kind=model_ladder_artifact_suppressed missing from worker.sh"
fi

# ── Test 3: suppression logic sits inside the capability-failure branch ────
# (i.e. it only runs when _cap_fail_class != "none", same gate RESILIENT-1007
# uses to skip cooldown/auto-block) — assert ordering via awk range extraction.
_block="$(awk '/_cap_fail_class="\$\(classify_model_capability_failure/,/^        fi$/' "$WORKER_SH")"
if [[ -n "$_block" ]] && grep -q 'model_ladder_artifact_suppressed' <<<"$_block" \
   && grep -q 'model_ladder_capability_escalation' <<<"$_block"; then
    ok "Test 3: artifact-suppression logic is nested in the same capability-failure branch as the escalation alert"
else
    fail "Test 3: artifact-suppression logic not found nested inside the capability-failure branch"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
