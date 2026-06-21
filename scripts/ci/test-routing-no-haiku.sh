#!/usr/bin/env bash
# RESILIENT-154 regression guard: sonnet is the fleet floor; haiku is removed.
#
# Haiku stalled ~60% of fleet cycles (ran cargo check on shell-only gaps,
# hesitated in --dangerously-skip-permissions → INFRA-705 kill / rc=124 timeout),
# and the cost rationale was void on a flat Claude subscription (haiku saves $0).
# Operator decision 2026-06-21: "Sonnet is the downgrade. Get rid of haiku."
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/
RY="$ROOT/../docs/dispatch/routing.yaml"
RF="$ROOT/dispatch/run-fleet.sh"
WK="$ROOT/dispatch/worker.sh"

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# (1) No haiku model_class routes remain.
# grep -c prints "0" AND exits 1 on no-match, so don't append `|| echo 0`
# (that double-prints) — capture the count and swallow grep's exit code.
n="$(grep -c 'model_class: haiku' "$RY" 2>/dev/null)" || true
[[ "${n:-0}" -eq 0 ]] && ok "routing.yaml has 0 'model_class: haiku' routes" || fail "routing.yaml still has $n haiku route(s)"

# (2) The xs and s routes resolve to sonnet (the formerly-haiku tiers).
grep -A2 'match: { effort: xs }' "$RY" | grep -q 'model_class: sonnet' \
  && ok "xs effort routes to sonnet" || fail "xs effort does not route to sonnet"
grep -A2 'match: { effort: s }' "$RY" | grep -q 'model_class: sonnet' \
  && ok "s effort routes to sonnet" || fail "s effort does not route to sonnet"

# (3) The fleet FLEET_MODEL default is sonnet, not haiku.
grep -q 'FLEET_MODEL="${FLEET_MODEL:-sonnet}"' "$RF" \
  && ok "run-fleet.sh default FLEET_MODEL=sonnet" || fail "run-fleet.sh default is not sonnet"
grep -q 'FLEET_MODEL="${FLEET_MODEL:-sonnet}"' "$WK" \
  && ok "worker.sh default FLEET_MODEL=sonnet" || fail "worker.sh default is not sonnet"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-routing-no-haiku.sh (sonnet is the floor; haiku removed)"
  exit 0
else
  echo "FAIL: test-routing-no-haiku.sh ($fails assertion(s) failed)"
  exit 1
fi
