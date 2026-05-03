#!/usr/bin/env bash
# test-pick-gap-worker-stagger.sh — INFRA-340 regression test.
#
# Pre-fix: every fleet worker called _pick_gap.py with the same inputs at
# boot time, got candidates[0] back, and 4-of-4 raced to the same gap
# (observed 2026-05-02 with chump-squad). Post-fix: WORKER_INDEX rotates
# the pick across the top-N candidates so simultaneously-booting siblings
# spread out instead of colliding.
#
# This test exercises the picker directly with a fixed candidate set and
# four worker indices, and asserts the four picks are pairwise distinct.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Six P1 INFRA xs/s gaps — top-4 should be returned for workers 1..4.
cat >"$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-100","domain":"INFRA","priority":"P1","effort":"xs","created_at":1000,"depends_on":""},
  {"id":"INFRA-101","domain":"INFRA","priority":"P1","effort":"xs","created_at":1001,"depends_on":""},
  {"id":"INFRA-102","domain":"INFRA","priority":"P1","effort":"s", "created_at":1002,"depends_on":""},
  {"id":"INFRA-103","domain":"INFRA","priority":"P1","effort":"s", "created_at":1003,"depends_on":""},
  {"id":"INFRA-104","domain":"INFRA","priority":"P1","effort":"m", "created_at":1004,"depends_on":""},
  {"id":"INFRA-105","domain":"INFRA","priority":"P1","effort":"m", "created_at":1005,"depends_on":""}
]
EOF

pick_for() {
    GAP_JSON_FILE="$TMP/gaps.json" \
    FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" \
    FLEET_EFFORT_FILTER="xs,s,m" \
    EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" \
    WORKER_INDEX="$1" \
    python3 "$PICKER"
}

# ── Test 1: four workers booting simultaneously pick four DIFFERENT gaps ─────
echo "Test 1: workers 1..4 pick distinct gaps"
P1=$(pick_for 1); P2=$(pick_for 2); P3=$(pick_for 3); P4=$(pick_for 4)
echo "  worker 1 → $P1"
echo "  worker 2 → $P2"
echo "  worker 3 → $P3"
echo "  worker 4 → $P4"
distinct=$(printf '%s\n%s\n%s\n%s\n' "$P1" "$P2" "$P3" "$P4" | sort -u | wc -l | tr -d ' ')
if [[ "$distinct" == "4" ]]; then
    echo "  PASS (4 distinct picks)"
else
    echo "  FAIL (expected 4 distinct, got $distinct)"
    exit 1
fi

# ── Test 2: worker_index wraps when it exceeds candidate count ──────────────
# 6 candidates, worker 7: (7-1) % 6 = 0 → candidate[0] (= worker 1's pick).
echo "Test 2: worker 7 wraps to candidate[0] (same as worker 1)"
P7=$(pick_for 7)
if [[ "$P7" == "$P1" ]]; then
    echo "  PASS (worker 7 → $P7, same as worker 1)"
else
    echo "  FAIL (expected $P1, got $P7)"
    exit 1
fi

# ── Test 3: missing/invalid WORKER_INDEX defaults to 1 (back-compat) ────────
echo "Test 3: missing WORKER_INDEX defaults to first candidate"
P_MISSING=$(GAP_JSON_FILE="$TMP/gaps.json" FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" python3 "$PICKER")
P_BAD=$(WORKER_INDEX="not-an-int" pick_for "not-an-int" 2>/dev/null || true)
if [[ "$P_MISSING" == "$P1" && "$P_BAD" == "$P1" ]]; then
    echo "  PASS (both fall back to candidate[0])"
else
    echo "  FAIL (missing=$P_MISSING bad=$P_BAD expected both=$P1)"
    exit 1
fi

# ── Test 4: ACTIVE_GAPS shrinks the candidate list; offset still works ──────
echo "Test 4: with ACTIVE_GAPS holding the top 2, worker 1 picks the 3rd"
P_AFTER_CLAIM=$(GAP_JSON_FILE="$TMP/gaps.json" FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="$P1 $P2" WORKER_INDEX="1" python3 "$PICKER")
if [[ "$P_AFTER_CLAIM" == "$P3" ]]; then
    echo "  PASS (top 2 in ACTIVE_GAPS → worker 1 gets 3rd: $P_AFTER_CLAIM)"
else
    echo "  FAIL (expected $P3, got $P_AFTER_CLAIM)"
    exit 1
fi

echo ""
echo "All pick-gap stagger tests passed."
