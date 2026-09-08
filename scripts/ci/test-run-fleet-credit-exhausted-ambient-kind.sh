#!/usr/bin/env bash
# test-run-fleet-credit-exhausted-ambient-kind.sh — CREDIBLE-130 AC3.
#
# Static coverage for the distinct `fleet_credit_exhausted` ambient kind: the
# INFRA-621 launch probe in run-fleet.sh must emit it (in addition to the
# generic fleet_auth_misconfigured event) whenever classify_probe_error()
# returns "credit-exhausted", so a consumer scanning kinds — not parsing an
# error_class field buried inside a generically-named auth event — can tell
# billing exhaustion apart from a dead credential.
#
# A full end-to-end run isn't practical here (the probe shells out to the
# real `claude` CLI), so this asserts the shipped source directly, matching
# the scanner-anchor pattern used elsewhere for hard-to-integration-test
# fleet scripts (e.g. test-bot-merge-stall-monitor.sh).
#
# Run from repo root: bash scripts/ci/test-run-fleet-credit-exhausted-ambient-kind.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RF="$ROOT/scripts/dispatch/run-fleet.sh"
RECALL="$ROOT/scripts/dispatch/operator-recall.sh"
REGISTRY="$ROOT/docs/observability/EVENT_REGISTRY.yaml"

PASS=0
FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo ""
echo "── run-fleet fleet_credit_exhausted ambient-kind tests (CREDIBLE-130) ──"

[[ -f "$RF" ]] || { echo "FAIL: run-fleet.sh not found at $RF"; exit 1; }
[[ -f "$RECALL" ]] || { echo "FAIL: operator-recall.sh not found at $RECALL"; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "FAIL: EVENT_REGISTRY.yaml not found at $REGISTRY"; exit 1; }

if grep -q '"kind":"fleet_credit_exhausted"' "$RF"; then
    ok "run-fleet.sh emits kind=fleet_credit_exhausted"
else
    bad "run-fleet.sh missing kind=fleet_credit_exhausted emission"
fi

# The emission must be gated on the credit-exhausted class, not fired for
# every probe failure (that would defeat the purpose of a *distinct* kind).
if awk '/kind":"fleet_credit_exhausted"/{print; exit}' "$RF" \
    | grep -q 'fleet_credit_exhausted' \
    && grep -B5 '"kind":"fleet_credit_exhausted"' "$RF" | grep -q 'credit-exhausted'; then
    ok "fleet_credit_exhausted emission is gated on error_class=credit-exhausted"
else
    bad "fleet_credit_exhausted emission is not gated on credit-exhausted class"
fi

if grep -q 'kind: fleet_credit_exhausted' "$REGISTRY"; then
    ok "EVENT_REGISTRY.yaml has an entry for fleet_credit_exhausted"
else
    bad "EVENT_REGISTRY.yaml missing fleet_credit_exhausted entry"
fi

if grep -q '"kind":"fleet_credit_exhausted"' "$RECALL"; then
    ok "operator-recall.sh explicitly reads fleet_credit_exhausted (routes it, doesn't ignore it)"
else
    bad "operator-recall.sh does not reference fleet_credit_exhausted at all"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
