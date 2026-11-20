#!/usr/bin/env bash
# scripts/ci/test-resilient-349-pr-stuck-live-scan.sh — RESILIENT-349
#
# Verifies the full PR-sitting chain is wired COTG (Claim-On-The-Go / works
# OOTB on a fresh node):
#   1. A live-scan emitter (stuck-pr-filer.sh, INFRA-307) is installed via
#      install-node-housekeeping.sh's ORGANS table + self-test loop, so every
#      node emits kind=pr_stuck from real GitHub state.
#   2. pr-stuck-cluster-detector.sh (the consumer) is ALSO installed, so
#      something actually reads those events.
#   3. stuck-pr-filer.sh emits a "gap" field (not just the legacy
#      "filed_gap") on its kind=pr_stuck events, matching the field name
#      pr-stuck-cluster-detector.sh's parser reads (ev.get('gap','')) —
#      without this, escalation gaps/chronic notices carry an empty
#      "Originating gap:" even though a gap was filed.
#   4. pr_stuck_chronic is registered in PLAYBOOK_REGISTRY.yaml so
#      duty-officer-loop.sh actually routes chronic single-PR escalations
#      instead of treating them as "unregistered" (defaults to page).
#
# Fails without RESILIENT-349: both organs are absent from ORGANS/self-test
# (a fresh node never emits or consumes kind=pr_stuck live), the emitted
# event has no "gap" field, and pr_stuck_chronic has no registry entry.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOUSEKEEPING="$REPO_ROOT/scripts/setup/install-node-housekeeping.sh"
FILER="$REPO_ROOT/scripts/ops/stuck-pr-filer.sh"
DETECTOR="$REPO_ROOT/scripts/coord/pr-stuck-cluster-detector.sh"
REGISTRY="$REPO_ROOT/docs/process/PLAYBOOK_REGISTRY.yaml"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

[ -f "$HOUSEKEEPING" ] || { echo "FATAL: $HOUSEKEEPING not found"; exit 1; }
[ -f "$FILER" ] || { echo "FATAL: $FILER not found"; exit 1; }
[ -f "$DETECTOR" ] || { echo "FATAL: $DETECTOR not found"; exit 1; }
[ -f "$REGISTRY" ] || { echo "FATAL: $REGISTRY not found"; exit 1; }

# T1: emitter organ entry present, wired to the real live-scan script
if grep -qE '^pr-stuck-live-scan\|scripts/ops/stuck-pr-filer\.sh\|[0-9]+"?$' "$HOUSEKEEPING"; then
    pass "T1: pr-stuck-live-scan organ wired to stuck-pr-filer.sh"
else
    fail "T1" "no 'pr-stuck-live-scan|scripts/ops/stuck-pr-filer.sh|<cadence>' line in ORGANS table"
fi

# T2: consumer organ entry present, wired with --apply so it actually files gaps
if grep -qE '^pr-stuck-cluster-detector\|scripts/coord/pr-stuck-cluster-detector\.sh --apply\|[0-9]+"?$' "$HOUSEKEEPING"; then
    pass "T2: pr-stuck-cluster-detector organ wired with --apply"
else
    fail "T2" "no 'pr-stuck-cluster-detector|scripts/coord/pr-stuck-cluster-detector.sh --apply|<cadence>' line in ORGANS table"
fi

# T3: both organs included in the post-install self-test loop
selftest_line="$(grep -n '^for name in' "$HOUSEKEEPING" | tail -1)"
if printf '%s' "$selftest_line" | grep -q 'pr-stuck-live-scan' && printf '%s' "$selftest_line" | grep -q 'pr-stuck-cluster-detector'; then
    pass "T3: both organs included in self-test loop"
else
    fail "T3" "self-test loop missing pr-stuck-live-scan and/or pr-stuck-cluster-detector: $selftest_line"
fi

# T4: stuck-pr-filer emits a "gap" field on kind=pr_stuck (matches the
# cluster-detector's ev.get('gap','') parser), not only the legacy "filed_gap"
if grep -qE '"kind":"pr_stuck".*"gap":"%s"' "$FILER"; then
    pass "T4: stuck-pr-filer.sh emits gap field on kind=pr_stuck"
else
    fail "T4" "kind=pr_stuck emit line in stuck-pr-filer.sh has no \"gap\":\"%s\" field"
fi

# T5: pr_stuck_chronic is a registered duty-officer signal (else the chronic
# escalation dead-ends as 'unregistered' -> defaults to paging the operator
# for every chronic PR instead of routing through the runbook)
if grep -qE '^\s*-\s*signal:\s*pr_stuck_chronic\s*$' "$REGISTRY"; then
    pass "T5: pr_stuck_chronic registered in PLAYBOOK_REGISTRY.yaml"
else
    fail "T5" "no '- signal: pr_stuck_chronic' block in $REGISTRY"
fi

# T6: syntax check on all touched scripts
for f in "$HOUSEKEEPING" "$FILER" "$DETECTOR"; do
    if bash -n "$f" 2>/dev/null; then
        pass "T6: bash -n OK for $(basename "$f")"
    else
        fail "T6" "bash -n failed on $f"
    fi
done

echo
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "${FAILURES[@]}"
    exit 1
fi
exit 0
