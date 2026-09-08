#!/usr/bin/env bash
# EFFECTIVE-1543 — the picker must exclude done/shipped/linked gaps from the
# pickable set, not just trust the JSON `status` field.
#
# Root cause it guards: `chump gap list --json` can return stale / split-brain
# rows (the gap store has multiple drifting reps). A gap with a linked closed_pr
# or a shipped_in marker is DONE regardless of what `status` claims, and must
# never be re-picked (observed: EFFECTIVE-449 status=already_satisfied +
# closed_pr=4381 re-picked into a duplicate PR #4527, queue never draining).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
CLAIMER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

tmp=$(mktemp)
trap "rm -f $tmp" EXIT

run() {
  GAP_JSON_FILE="$tmp" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
    python3 "$PICKER"
}

AC='the gap is fixed and tested'  # non-vague AC so INFRA-1259 keeps it pickable

# 1. closed_pr set on an "open" gap → must be excluded.
cat > "$tmp" <<JSON
[
  {"id":"INFRA-100","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC","closed_pr":4525},
  {"id":"INFRA-200","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON
r="$(run)"
[ "$r" = "INFRA-200" ] && pass "skips open gap with closed_pr set (got INFRA-200)" \
  || fail "closed_pr gap not excluded (got '$r', want INFRA-200)"

# 2. shipped_in set on an "open" gap → must be excluded.
cat > "$tmp" <<JSON
[
  {"id":"INFRA-100","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC","shipped_in":"#4525"},
  {"id":"INFRA-200","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON
r="$(run)"
[ "$r" = "INFRA-200" ] && pass "skips open gap with shipped_in set (got INFRA-200)" \
  || fail "shipped_in gap not excluded (got '$r', want INFRA-200)"

# 3. status=already_satisfied → must be excluded even with no closed_pr.
cat > "$tmp" <<JSON
[
  {"id":"INFRA-100","status":"already_satisfied","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"},
  {"id":"INFRA-200","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON
r="$(run)"
[ "$r" = "INFRA-200" ] && pass "skips already_satisfied gap (got INFRA-200)" \
  || fail "already_satisfied gap not excluded (got '$r', want INFRA-200)"

# 4. every gap is done-like (shipped / ready_to_ship / already_satisfied) → nothing.
cat > "$tmp" <<JSON
[
  {"id":"INFRA-100","status":"shipped","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"},
  {"id":"INFRA-200","status":"ready_to_ship","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"},
  {"id":"INFRA-300","status":"already_satisfied","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON
r="$(run)"
[ -z "$r" ] && pass "returns nothing when all gaps are done-like" \
  || fail "returned '$r' when only done-like gaps existed"

# 5. parity: _pick_and_claim_gap.py must share the same pickability gate.
grep -q "_is_pickable_open" "$CLAIMER" \
  && pass "_pick_and_claim_gap.py uses _is_pickable_open (parity with canonical picker)" \
  || fail "_pick_and_claim_gap.py missing _is_pickable_open gate"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
