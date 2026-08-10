#!/usr/bin/env bash
# RESILIENT-272 regression — pickers must filter out manufactured
# "pillar starved" self-referential junk gaps (banned by CLAUDE.md
# Mission-Driver §2). A helsinki 2nd-host fleet was observed grinding
# 0/10 on exactly this junk class (INFRA-2789 "MISSION-ZERO-WASTE:
# pillar starved", INFRA-2802 "MISSION-RESILIENT: pillar starved")
# because these titles match the FLEET-046/INFRA-720 starved-pillar
# rebalance boost, so the picker kept ranking them ahead of real work.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICK_GAP="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
PICK_AND_CLAIM="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

tmp=$(mktemp)
lock_dir=$(mktemp -d)
trap 'rm -f "$tmp"; rm -rf "$lock_dir"' EXIT

# Fixture: one manufactured junk gap (must skip), one real gap (must pick).
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-2789","title":"MISSION-ZERO-WASTE: pillar starved","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"refill the pillar"},
  {"id":"INFRA-2802","title":"MISSION-RESILIENT: pillar starved","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"refill the pillar"},
  {"id":"INFRA-3001","title":"RESILIENT: real work item","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"do the real thing"}
]
JSON

# ── _pick_gap.py ─────────────────────────────────────────────────────────
result=$(GAP_JSON_FILE="$tmp" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
  CHUMP_REBALANCE=0 python3 "$PICK_GAP")
if [ "$result" = "INFRA-3001" ]; then
  pass "_pick_gap.py skips manufactured pillar-starved junk, picks real work"
else
  fail "_pick_gap.py picked '$result' instead of the real-work gap INFRA-3001"
fi

# All-junk fixture: must return nothing.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-2789","title":"MISSION-ZERO-WASTE: pillar starved","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"refill the pillar"},
  {"id":"INFRA-2802","title":"MISSION-RESILIENT: pillar starved","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"refill the pillar"}
]
JSON
result=$(GAP_JSON_FILE="$tmp" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
  CHUMP_REBALANCE=0 python3 "$PICK_GAP")
if [ -z "$result" ]; then
  pass "_pick_gap.py returns nothing when only junk gaps are open"
else
  fail "_pick_gap.py returned '$result' when only junk gaps existed"
fi

# ── _pick_and_claim_gap.py ──────────────────────────────────────────────
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-2789","title":"MISSION-ZERO-WASTE: pillar starved","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"refill the pillar"},
  {"id":"INFRA-2802","title":"MISSION-RESILIENT: pillar starved","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"refill the pillar"},
  {"id":"INFRA-3001","title":"RESILIENT: real work item","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"do the real thing"}
]
JSON
result=$(CHUMP_SESSION_ID="test-session-1" GAP_JSON_FILE="$tmp" CHUMP_LOCK_DIR="$lock_dir" \
  FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m CHUMP_REBALANCE=0 WORKER_INDEX=1 \
  python3 "$PICK_AND_CLAIM")
if [ "$result" = "INFRA-3001" ]; then
  pass "_pick_and_claim_gap.py skips manufactured pillar-starved junk, picks real work"
else
  fail "_pick_and_claim_gap.py picked '$result' instead of the real-work gap INFRA-3001"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
