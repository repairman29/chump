#!/usr/bin/env bash
# test-mission-picker.sh — MISSION-011
#
# Verifies that scripts/dispatch/_pick_gap.py surfaces mission-linked gaps
# BEFORE equal-priority substrate gaps, and that a substrate P0 still beats
# a mission P1 (the boost is bounded, not absolute).
#
# Acceptance criteria covered:
#   AC1: a mission-linked P1 is picked before an unlinked P1 substrate gap
#   AC2: a substrate P0 still beats a mission P1 (boost is additive, not a
#        total override — a manual P0 is NOT needed for mission gaps to win
#        within their priority band, but a legitimate P0 still trumps)
#   AC3: mission boost works via all four detection paths:
#         (a) outcome_id FK match
#         (b) domain=MISSION
#         (c) gap.id == active_mission
#         (d) verbatim active_mission ID in title / notes / description
#   AC4: CHUMP_ACTIVE_MISSION="" disables the boost (pure priority ordering)
#   AC5: kind=picker_mission_boost emitted when boost influenced the pick
#   AC-MISSION-040: dependency-ordered ranking composes with mission ranking —
#        a mission-linked gap with no open deps is picked over a same-pri/effort
#        gap linked to a different outcome that has an unresolved open dep.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

echo "=== MISSION-011 mission-picker tests ==="
[[ -f "$PICKER" ]] || { fail "picker not at $PICKER"; exit 1; }
ok "picker present"

TMP="$(mktemp -d -t mission-picker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

# Helper: run picker with a given gaps.json content and env vars.
run_picker() {
    local gaps_file="$1"; shift
    GAP_JSON_FILE="$gaps_file" \
    CHUMP_REPO="$TMP" \
    CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" \
    FLEET_MODEL=opus \
    WORKER_INDEX=1 \
    WORKER_ID=test-worker \
      "$@" python3 "$PICKER"
}

# ── Test 1: mission P1 beats substrate P1 (the core invariant) ───────────────
# Two gaps, identical priority+effort+age. One is domain=MISSION, the other
# is domain=INFRA. Mission gap must be picked first.
cat > "$TMP/t1.json" <<'EOF'
[
  {"id":"INFRA-SUB","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate gap, non-mission domain.\"]",
   "title":"Substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission keystone gap.\"]",
   "title":"Mission keystone","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t1.json")"
if [[ "$picked" == "MISSION-KEY" ]]; then
    ok "AC1 (domain=MISSION): mission P1 beats substrate P1"
else
    fail "AC1 (domain=MISSION): expected MISSION-KEY, got '$picked'"
fi

# ── Test 2: substrate P0 still beats mission P1 (boost is bounded) ───────────
cat > "$TMP/t2.json" <<'EOF'
[
  {"id":"INFRA-P0","domain":"INFRA","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate P0 gap.\"]",
   "title":"Substrate P0","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission keystone gap.\"]",
   "title":"Mission keystone","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t2.json")"
if [[ "$picked" == "INFRA-P0" ]]; then
    ok "AC2: substrate P0 still beats mission P1 (boost is additive, not absolute)"
else
    fail "AC2: expected INFRA-P0, got '$picked'"
fi

# ── Test 3a: outcome_id FK detection ─────────────────────────────────────────
cat > "$TMP/t3a.json" <<'EOF'
[
  {"id":"INFRA-SUB","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate gap.\"]",
   "title":"Substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"EFFECTIVE-KEY","domain":"EFFECTIVE","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Effective gap linked via outcome_id FK.\"]",
   "title":"Effective gap for BEAST onboard","outcome_id":"MISSION-010",
   "notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t3a.json")"
if [[ "$picked" == "EFFECTIVE-KEY" ]]; then
    ok "AC3a (outcome_id FK): gap linked via outcome_id beats substrate P1"
else
    fail "AC3a (outcome_id FK): expected EFFECTIVE-KEY, got '$picked'"
fi

# ── Test 3b: verbatim mission ID in title detection ───────────────────────────
cat > "$TMP/t3b.json" <<'EOF'
[
  {"id":"INFRA-SUB","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate gap.\"]",
   "title":"Substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"EFFECTIVE-TITLE","domain":"EFFECTIVE","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Gap whose title mentions the mission.\"]",
   "title":"Fix clone auth — blocks MISSION-010 BEAST onboard",
   "outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t3b.json")"
if [[ "$picked" == "EFFECTIVE-TITLE" ]]; then
    ok "AC3b (title mention): gap mentioning active mission in title beats substrate P1"
else
    fail "AC3b (title mention): expected EFFECTIVE-TITLE, got '$picked'"
fi

# ── Test 3c: verbatim mission ID in description detection ────────────────────
cat > "$TMP/t3c.json" <<'EOF'
[
  {"id":"INFRA-SUB","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate gap.\"]",
   "title":"Substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"EFFECTIVE-DESC","domain":"EFFECTIVE","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Gap whose description mentions the mission.\"]",
   "title":"onboard: support private repos",
   "outcome_id":null,"notes":"",
   "description":"This is the critical unblock for MISSION-010 — the 0to1 autonomous fleet."}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t3c.json")"
if [[ "$picked" == "EFFECTIVE-DESC" ]]; then
    ok "AC3c (description mention): gap mentioning active mission in description beats substrate P1"
else
    fail "AC3c (description mention): expected EFFECTIVE-DESC, got '$picked'"
fi

# ── Test 4: CHUMP_ACTIVE_MISSION="" disables boost → pure priority ordering ──
cat > "$TMP/t4.json" <<'EOF'
[
  {"id":"INFRA-FIRST","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate gap filed first.\"]",
   "title":"Substrate gap, filed first","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission gap filed second.\"]",
   "title":"Mission keystone","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION="" run_picker "$TMP/t4.json")"
if [[ "$picked" == "INFRA-FIRST" ]]; then
    ok "AC4: CHUMP_ACTIVE_MISSION=\"\" disables boost; legacy first-fit picks INFRA-FIRST"
else
    fail "AC4: expected INFRA-FIRST (boost disabled), got '$picked'"
fi

# ── Test 5: kind=picker_mission_boost emitted when boost displaced a gap ─────
cat > "$TMP/t5.json" <<'EOF'
[
  {"id":"INFRA-SUB","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate gap.\"]",
   "title":"Substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission keystone gap.\"]",
   "title":"Mission keystone","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t5.json" > /dev/null
if grep -q '"kind": "picker_mission_boost"' "$TMP/.chump-locks/ambient.jsonl" \
   && grep -q '"active_mission": "MISSION-010"' "$TMP/.chump-locks/ambient.jsonl"; then
    ok "AC5: kind=picker_mission_boost emitted with active_mission when boost displaced a substrate gap"
else
    fail "AC5: ambient missing picker_mission_boost emit; got: $(cat "$TMP/.chump-locks/ambient.jsonl")"
fi

# ── Test 6: multiple mission gaps — highest-priority mission gap wins ─────────
# mission P2 vs substrate P1 — substrate P1 should win (prio_rank still used)
cat > "$TMP/t6.json" <<'EOF'
[
  {"id":"INFRA-P1","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate P1.\"]",
   "title":"Substrate P1","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-P2","domain":"MISSION","priority":"P2","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P2 gap.\"]",
   "title":"Mission P2 keystone","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t6.json")"
if [[ "$picked" == "INFRA-P1" ]]; then
    ok "AC2-ext: substrate P1 beats mission P2 (boost only wins within same priority band)"
else
    fail "AC2-ext: expected INFRA-P1 over mission P2, got '$picked'"
fi

# ── Test 7 (MISSION-026): P0 mission gap beats P0 self-maintenance gap ────────
# The core regression: a P0 domain=MISSION gap must be picked over a P0
# substrate gap of the same effort/age. Before MISSION-026 the planner_rank
# was the primary sort key, so a planner-ranked substrate gap could outrank
# an unranked P0 mission gap.
cat > "$TMP/t7.json" <<'EOF'
[
  {"id":"INFRA-MAINT","domain":"INFRA","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Self-maintenance substrate gap at P0.\"]",
   "title":"Self-maintenance substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P0","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P0 gap.\"]",
   "title":"Mission P0 keystone","outcome_id":null,"notes":"","description":""}
]
EOF
# Simulate planner ranking the substrate gap highly (rank=1) while the mission
# gap has no planner entry (rank=10000). Before fix, INFRA-MAINT would win.
PRIORITY_JSON="$TMP/.chump-locks/gap-priority.json"
printf '{"items":[{"gap_id":"INFRA-MAINT","rank":1}]}\n' > "$PRIORITY_JSON"
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=sonnet run_picker "$TMP/t7.json")"
rm -f "$PRIORITY_JSON"
if [[ "$picked" == "MISSION-KEY" ]]; then
    ok "AC-MISSION-026a: P0 mission gap beats P0 substrate gap even when planner ranks substrate (planner can't override prio)"
else
    fail "AC-MISSION-026a: expected MISSION-KEY over planner-ranked INFRA-MAINT, got '$picked'"
fi

# ── Test 8 (MISSION-026): substrate P0 still beats mission P1 (invariant preserved) ──
# The invariant from MISSION-011 must hold after the MISSION-026 fix: a
# substrate P0 must still outrank a mission P1 (priority wins over mission boost).
cat > "$TMP/t8.json" <<'EOF'
[
  {"id":"INFRA-P0","domain":"INFRA","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate P0 gap.\"]",
   "title":"Substrate P0 gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-P1","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P1 gap.\"]",
   "title":"Mission P1 keystone","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=sonnet run_picker "$TMP/t8.json")"
if [[ "$picked" == "INFRA-P0" ]]; then
    ok "AC-MISSION-026b: substrate P0 still beats mission P1 (priority invariant preserved)"
else
    fail "AC-MISSION-026b: expected INFRA-P0 over mission P1, got '$picked'"
fi

# ── Test 9 (MISSION-026): xs-effort P0 MISSION gap is NOT skipped by sonnet worker ──
# Before MISSION-026, a sonnet worker unconditionally skipped xs-effort gaps,
# permanently blocking xs P0 MISSION gaps like MISSION-018.
cat > "$TMP/t9.json" <<'EOF'
[
  {"id":"MISSION-XS","domain":"MISSION","priority":"P0","effort":"xs","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. xs-effort P0 MISSION gap.\"]",
   "title":"xs P0 mission gap","outcome_id":null,"notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=sonnet run_picker "$TMP/t9.json")"
if [[ "$picked" == "MISSION-XS" ]]; then
    ok "AC-MISSION-026c: xs-effort P0 MISSION gap is NOT skipped by sonnet worker (effort gate exception)"
else
    fail "AC-MISSION-026c: expected MISSION-XS to be picked by sonnet worker, got '$picked' (xs P0 mission blocked by effort gate)"
fi

# ── Test 10 (MISSION-040): dependency-ordered ranking composes with mission rank ──
# A: linked to ACTIVE_MISSION via outcome_id, no deps.
# B: linked to a different outcome, has an open (unresolved) dependency.
# Same priority/effort/age band — picker must choose A because B's dependency
# is not yet done (deps-first rule), even though B would otherwise be a
# same-priority substrate-vs-mission tiebreak candidate.
cat > "$TMP/t10.json" <<'EOF'
[
  {"id":"OTHER-DEP","domain":"INFRA","priority":"P2","effort":"s","status":"open",
   "created_at":900,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Unrelated open dependency gap.\"]",
   "title":"Unrelated blocker","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-A","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission-linked gap with no deps.\"]",
   "title":"Mission-linked, no deps","outcome_id":"MISSION-010","notes":"","description":""},
  {"id":"OTHER-B","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[\"OTHER-DEP\"]",
   "acceptance_criteria":"[\"1. Different-outcome gap blocked by an open dep.\"]",
   "title":"Different outcome, blocked","outcome_id":"EFFECTIVE-000","notes":"","description":""}
]
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 run_picker "$TMP/t10.json")"
if [[ "$picked" == "MISSION-A" ]]; then
    ok "AC-MISSION-040: mission-linked gap with no deps beats same-pri gap blocked by an open dep"
else
    fail "AC-MISSION-040: expected MISSION-A, got '$picked'"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed assertions:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
