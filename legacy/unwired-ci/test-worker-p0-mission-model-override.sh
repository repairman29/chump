#!/usr/bin/env bash
# MISSION-048 regression guard.
#
# A P0 + domain=MISSION gap with effort>=m must spawn claude on SONNET, not the
# routing.yaml cost-downgraded HAIKU. Haiku stalls on m+ effort (INFRA-705
# stall-detector kills the cycle; 30-min timeouts), so although MISSION-047 made
# the picker CLAIM such gaps, they never finish on haiku. This override (sibling
# of MISSION-047: pickability vs capability) forces sonnet for that exact class.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/
W="$ROOT/dispatch/worker.sh"
[[ -f "$W" ]] || { echo "FAIL: worker.sh not found"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- static: the override exists with the right guard, condition, and action ---
grep -q 'MISSION-048' "$W" && ok "MISSION-048 override present" || fail "no MISSION-048 override"
grep -qF "p == 'P0' and dom == 'MISSION' and e in ('m', 'l', 'xl')" "$W" \
  && ok "condition = P0 + domain=MISSION + effort in m/l/xl" || fail "override condition wrong/missing"
grep -qF 'FLEET_MODEL="sonnet"' "$W" && ok "forces FLEET_MODEL=sonnet" || fail "does not force sonnet"
grep -qF 'if [[ "$FLEET_MODEL" == "haiku" ]]; then' "$W" && ok "only overrides a haiku resolution" || fail "missing haiku guard"

# --- behavioral: the decision (mirrors worker.sh) for the 3 boundary cases ---
decide() {  # stdin=gap_json, $1=GAP_ID -> prints 1 (override) or 0
  GAP_ID="$1" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
gid = os.environ['GAP_ID']
g = next((x for x in d.get('gaps', []) if x.get('id') == gid), None) \
    or next((x for x in [d] if x.get('id') == gid), {})
p = (g.get('priority') or '').upper()
dom = (g.get('domain') or '').upper()
e = (g.get('effort') or '').lower()
print('1' if (p == 'P0' and dom == 'MISSION' and e in ('m', 'l', 'xl')) else '0')
"
}
[[ "$(decide MISSION-1 <<<'{"id":"MISSION-1","priority":"P0","domain":"MISSION","effort":"m"}')" == "1" ]] \
  && ok "P0-MISSION/m -> override to sonnet" || fail "P0-MISSION/m was NOT overridden"
[[ "$(decide INFRA-1 <<<'{"id":"INFRA-1","priority":"P1","domain":"INFRA","effort":"m"}')" == "0" ]] \
  && ok "P1/m -> no override (haiku fine, no over-spend)" || fail "P1/m wrongly overridden"
[[ "$(decide MISSION-2 <<<'{"id":"MISSION-2","priority":"P0","domain":"MISSION","effort":"xs"}')" == "0" ]] \
  && ok "P0-MISSION/xs -> no override (haiku handles xs)" || fail "P0-MISSION/xs wrongly overridden"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-worker-p0-mission-model-override.sh (P0-MISSION m+ runs on sonnet)"
  exit 0
else
  echo "FAIL: test-worker-p0-mission-model-override.sh ($fails assertion(s) failed)"
  exit 1
fi
