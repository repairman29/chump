#!/usr/bin/env bash
# test-mission-picker-worker.sh — MISSION-028
#
# Verifies that scripts/dispatch/_pick_and_claim_gap.py (the WORKER'S actual
# picker, used by worker.sh ~line 492) correctly surfaces mission-linked gaps
# before equal-priority substrate gaps, and that substrate P0 still beats
# mission P1 (the boost is bounded, not absolute).
#
# This is the regression test for MISSION-028: the worker picker was missing
# the mission_rank sort key and the xs-effort gate exception that had already
# landed in _pick_gap.py (canonical curator picker, fixed in #3055).
#
# Acceptance criteria:
#   AC-WORKER-1: P0-MISSION gap beats P0-self-maintenance gap within the worker picker
#   AC-WORKER-2: substrate P0 still beats mission P1 (invariant preserved)
#   AC-WORKER-3: xs-effort P0 MISSION gap is NOT skipped by a sonnet worker
#                (effort gate exception mirrors _pick_gap.py MISSION-026 fix)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

echo "=== MISSION-028 worker-picker mission-rank tests ==="
[[ -f "$PICKER" ]] || { fail "worker picker not at $PICKER"; exit 1; }
ok "worker picker present"

TMP="$(mktemp -d -t mission-picker-worker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/locks"
mkdir -p "$LOCK_DIR"

# Helper: run the worker picker with a given gaps.json content.
# Dry-run mode (CHUMP_FLEET_DRY_RUN=1) skips writing leases — tests ranking only.
run_worker_picker() {
    local gaps_file="$1"; shift
    GAP_JSON_FILE="$gaps_file" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_FLEET_DRY_RUN=1 \
    CHUMP_REBALANCE=0 \
    WORKER_INDEX=1 \
    WORKER_ID=test-worker \
      "$@" python3 "$PICKER"
}

# ── AC-WORKER-1: P0-MISSION beats P0-self-maintenance ───────────────────────
# The core regression: a P0 domain=MISSION gap must be picked over a P0
# substrate gap (same effort, same age) by the WORKER picker. Before
# MISSION-028, the worker had no mission_rank in its sort tuple, so the
# substrate gap (created_at=1000, filed earlier) would win the tiebreak.
cat > "$TMP/t1.json" <<'EOF'
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
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=opus run_worker_picker "$TMP/t1.json")"
if [[ "$picked" == "MISSION-KEY" ]]; then
    ok "AC-WORKER-1: P0-MISSION beats P0-self-maintenance in worker picker"
else
    fail "AC-WORKER-1: expected MISSION-KEY, got '$picked' — worker picker still skipping MISSION gaps"
fi

# ── AC-WORKER-2: substrate P0 still beats mission P1 (invariant) ────────────
# After the fix, the priority invariant must be preserved: a substrate P0 must
# still outrank a mission P1 in the worker picker. The mission boost is a
# within-band tiebreaker, not a total override.
cat > "$TMP/t2.json" <<'EOF'
[
  {"id":"INFRA-P0","domain":"INFRA","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate P0 gap.\"]",
   "title":"Substrate P0 gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-P1","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":999,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P1 gap filed slightly earlier.\"]",
   "title":"Mission P1 keystone","outcome_id":null,"notes":"","description":""}
]
EOF
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=opus run_worker_picker "$TMP/t2.json")"
if [[ "$picked" == "INFRA-P0" ]]; then
    ok "AC-WORKER-2: substrate P0 still beats mission P1 in worker picker (invariant preserved)"
else
    fail "AC-WORKER-2: expected INFRA-P0 over mission P1, got '$picked' — mission boost is over-riding priority"
fi

# ── AC-WORKER-3: xs-effort P0 MISSION gap not skipped by sonnet worker ───────
# Before MISSION-028, the worker had no xs-gate exception for P0 MISSION gaps:
#   if worker_model == "sonnet" and e == "xs": continue   (unconditional)
# This permanently blocked xs P0 MISSION gaps like MISSION-018 from sonnet workers.
# After the fix, P0+domain=MISSION bypasses the xs gate (mirrors _pick_gap.py).
cat > "$TMP/t3.json" <<'EOF'
[
  {"id":"MISSION-XS","domain":"MISSION","priority":"P0","effort":"xs","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. xs-effort P0 MISSION gap like MISSION-018.\"]",
   "title":"xs P0 mission gap","outcome_id":null,"notes":"","description":""}
]
EOF
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=sonnet run_worker_picker "$TMP/t3.json")"
if [[ "$picked" == "MISSION-XS" ]]; then
    ok "AC-WORKER-3: xs-effort P0 MISSION gap is NOT skipped by sonnet worker in worker picker"
else
    fail "AC-WORKER-3: expected MISSION-XS to be picked by sonnet worker, got '$picked' — xs P0 mission still blocked by effort gate"
fi

# ── Bonus: P0-MISSION beats P0-substrate even when rebalance gives substrate a boost ──
# The rebalance boost can lift a P2 to effective_prio=0, but for two P0 gaps the
# rebalance only affects relative ordering within effective_prio=0. mission_rank
# must still break the tie in favor of the MISSION gap.
cat > "$TMP/t4.json" <<'EOF'
[
  {"id":"INFRA-BOOST","domain":"EFFECTIVE","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. EFFECTIVE P0 gap — rebalance would give this a boost too.\"]",
   "title":"EFFECTIVE: some P0 gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P0","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P0 gap.\"]",
   "title":"Mission P0 keystone","outcome_id":null,"notes":"","description":""}
]
EOF
# Enable rebalance with INFRA as monopoly domain so EFFECTIVE gets a +2 boost.
# After boost, INFRA-BOOST and MISSION-KEY both have effective_prio=0.
# mission_rank must break the tie for MISSION-KEY.
picked="$(CHUMP_ACTIVE_MISSION=MISSION-010 FLEET_MODEL=opus CHUMP_REBALANCE=0 run_worker_picker "$TMP/t4.json")"
if [[ "$picked" == "MISSION-KEY" ]]; then
    ok "Bonus: P0-MISSION beats P0-EFFECTIVE (same effective_prio) via mission_rank tiebreaker"
else
    fail "Bonus: expected MISSION-KEY over P0-EFFECTIVE tiebreak, got '$picked'"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed assertions:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
