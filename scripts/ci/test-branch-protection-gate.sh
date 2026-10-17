#!/usr/bin/env bash
# test-branch-protection-gate.sh — CREDIBLE-1502 (Phase R R3)
#
# The operator flipped live branch-protection on `main` to
# enforce_admins=true + required_status_checks.strict=true (contexts stay
# [verified]). This test makes that flip a constraint instead of a one-time
# fact: it asserts the checked-in baseline still reflects it, and (when gh +
# network are available) that the live rule hasn't drifted from the baseline.
#
# Two parts:
#   1. Pure-file check (always runs, no network): asserts
#      docs/baselines/branch-protection-main.json has enforce_admins.enabled,
#      required_status_checks.strict, and contexts == ["verified"].
#   2. Live check (skipped if gh/network unavailable): runs
#      scripts/ops/branch-protection-drift.sh --dry-run and fails on drift.
#   3. CREDIBLE-1510 merge-queue ruleset payload (pure-file, no network):
#      docs/baselines/ruleset-main-merge-queue.json is the exact body the
#      operator POSTs to /rulesets (docs/process/MERGE_QUEUE_FLIP.md). This
#      asserts its shape so the runbook can't rot: merge_queue rule with the
#      agreed parameters, targeting refs/heads/main, plus required check
#      `verified`.
#
# Rulesets are OUT OF SCOPE for the live drift check (part 2), on purpose:
# a GitHub merge queue is configured as a repository RULESET (rule type
# merge_queue), which layers on top of the classic branch-protection object
# and does not change it. GET branches/main/protection — the only thing
# branch-protection-drift.sh reads — is therefore identical before and after
# the merge-queue flip, so this gate tolerates the queue configuration with no
# baseline change. Live ruleset state is verified by the one-line check in
# docs/process/MERGE_QUEUE_FLIP.md, not by this gate (a live ruleset audit
# would page on every pre-flip run while the ruleset legitimately does not
# exist yet).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="$REPO_ROOT/docs/baselines/branch-protection-main.json"
DRIFT_SCRIPT="$REPO_ROOT/scripts/ops/branch-protection-drift.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== CREDIBLE-1502: branch-protection gate ==="

if [[ ! -f "$BASELINE" ]]; then
    bad "baseline missing: $BASELINE"
    echo "FAIL: $FAIL  PASS: $PASS"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    bad "jq not found — cannot evaluate baseline"
    echo "FAIL: $FAIL  PASS: $PASS"
    exit 1
fi

# ── 1. pure-file check ────────────────────────────────────────────────────
enforce_admins="$(jq -r '.enforce_admins.enabled' "$BASELINE")"
if [[ "$enforce_admins" == "true" ]]; then
    ok "baseline: enforce_admins.enabled == true"
else
    bad "baseline: enforce_admins.enabled == '$enforce_admins' (expected true)"
fi

strict="$(jq -r '.required_status_checks.strict' "$BASELINE")"
if [[ "$strict" == "true" ]]; then
    ok "baseline: required_status_checks.strict == true"
else
    bad "baseline: required_status_checks.strict == '$strict' (expected true)"
fi

contexts="$(jq -c '.required_status_checks.contexts' "$BASELINE")"
if [[ "$contexts" == '["verified"]' ]]; then
    ok "baseline: required_status_checks.contexts == [\"verified\"]"
else
    bad "baseline: required_status_checks.contexts == '$contexts' (expected [\"verified\"])"
fi

# ── 3. merge-queue ruleset payload (CREDIBLE-1510, pure-file) ────────────
RULESET="$REPO_ROOT/docs/baselines/ruleset-main-merge-queue.json"
if [[ ! -f "$RULESET" ]]; then
    bad "ruleset payload missing: $RULESET"
elif ! jq -e . "$RULESET" >/dev/null 2>&1; then
    bad "ruleset payload is not valid JSON: $RULESET"
else
    rs_check() {  # $1 = jq filter that must be true, $2 = label
        if jq -e "$1" "$RULESET" >/dev/null 2>&1; then ok "ruleset: $2"; else bad "ruleset: $2"; fi
    }
    rs_check '.target == "branch" and .enforcement == "active"' 'branch target, enforcement active'
    rs_check '.conditions.ref_name.include == ["refs/heads/main"]' 'targets refs/heads/main only'
    rs_check '[.rules[] | select(.type == "merge_queue")] | length == 1' 'exactly one merge_queue rule'
    rs_check '.rules[] | select(.type == "merge_queue") | .parameters
        | .merge_method == "SQUASH"
          and .grouping_strategy == "ALLGREEN"
          and .check_response_timeout_minutes == 60
          and .max_entries_to_build == 5
          and .min_entries_to_merge == 1
          and .max_entries_to_merge == 5
          and .min_entries_to_merge_wait_minutes == 2' 'merge_queue parameters match the agreed config'
    rs_check '.rules[] | select(.type == "required_status_checks") | .parameters
        | .strict_required_status_checks_policy == true
          and ([.required_status_checks[].context] == ["verified"])' 'required_status_checks == [verified], strict'
fi

# ── 2. live drift check (skipped without gh + network) ───────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "  SKIP: gh not found — skipping live drift check"
elif ! gh auth status >/dev/null 2>&1; then
    echo "  SKIP: gh not authenticated — skipping live drift check"
else
    if bash "$DRIFT_SCRIPT" --dry-run >/tmp/branch-protection-gate-live.$$ 2>&1; then
        if grep -q 'DRIFT detected' /tmp/branch-protection-gate-live.$$; then
            bad "live branch protection has drifted from baseline"
            cat /tmp/branch-protection-gate-live.$$
        else
            ok "live branch protection matches baseline"
        fi
    else
        echo "  SKIP: branch-protection-drift.sh --dry-run could not reach the API — skipping live check"
    fi
    rm -f /tmp/branch-protection-gate-live.$$
fi

echo ""
echo "FAIL: $FAIL  PASS: $PASS"
[[ "$FAIL" -eq 0 ]]
