#!/usr/bin/env bash
# test-infra-409-atomic-stagger.sh — INFRA-409 regression test.
#
# Pre-fix: worker.sh dropped ACTIVE_GAPS when switching from _pick_gap.py to
# _pick_and_claim_gap.py (INFRA-415 wiring commit). Without ACTIVE_GAPS, the
# picker's candidate list includes already-claimed gaps, so the stagger offset
# is computed on the wrong (too large) pool. Workers whose staggered slot
# points to a locked gap fall through and converge on the same remaining
# unclaimed gap instead of spreading across the available queue.
#
# Post-fix: ACTIVE_GAPS is passed again, candidates exclude in-progress gaps,
# and stagger spreads workers correctly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Six P1 gaps: top 2 actively worked by siblings (ACTIVE_GAPS).
# Workers 1-4 should spread across the remaining 4.
cat >"$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-100","domain":"INFRA","priority":"P1","effort":"xs","created_at":1000,"depends_on":"","status":"open"},
  {"id":"INFRA-101","domain":"INFRA","priority":"P1","effort":"xs","created_at":1001,"depends_on":"","status":"open"},
  {"id":"INFRA-102","domain":"INFRA","priority":"P1","effort":"s", "created_at":1002,"depends_on":"","status":"open"},
  {"id":"INFRA-103","domain":"INFRA","priority":"P1","effort":"s", "created_at":1003,"depends_on":"","status":"open"},
  {"id":"INFRA-104","domain":"INFRA","priority":"P1","effort":"m", "created_at":1004,"depends_on":"","status":"open"},
  {"id":"INFRA-105","domain":"INFRA","priority":"P1","effort":"m", "created_at":1005,"depends_on":"","status":"open"}
]
EOF

lock_dir="$TMP/.chump-locks"
mkdir -p "$lock_dir"

pick_with_active() {
    local worker_idx="$1"
    local active="$2"
    CHUMP_SESSION_ID="session-stagger-$worker_idx" \
    GAP_JSON_FILE="$TMP/gaps.json" \
    CHUMP_LOCK_DIR="$lock_dir" \
    FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" \
    FLEET_EFFORT_FILTER="xs,s,m" \
    EXCLUDE_RE="^$" \
    ACTIVE_GAPS="$active" \
    WORKER_INDEX="$worker_idx" \
    python3 "$PICKER" 2>/dev/null || true
}

# ── Test 1: stagger distributes across unclaimed gaps when top 2 are active ──
echo "Test 1: workers 1..4 spread across bottom 4 gaps when top 2 are ACTIVE"
rm -rf "$lock_dir" && mkdir -p "$lock_dir"
ACTIVE="INFRA-100 INFRA-101"
P1=$(pick_with_active 1 "$ACTIVE")
P2=$(pick_with_active 2 "$ACTIVE")
P3=$(pick_with_active 3 "$ACTIVE")
P4=$(pick_with_active 4 "$ACTIVE")
echo "  worker 1 → $P1"
echo "  worker 2 → $P2"
echo "  worker 3 → $P3"
echo "  worker 4 → $P4"
distinct=$(printf '%s\n%s\n%s\n%s\n' "$P1" "$P2" "$P3" "$P4" | sort -u | wc -l | tr -d ' ')
if [[ "$distinct" == "4" ]]; then
    echo "  PASS (4 distinct picks from unclaimed pool)"
else
    echo "  FAIL (expected 4 distinct, got $distinct — stagger broken without ACTIVE_GAPS)"
    exit 1
fi
# All picks must be from the unclaimed pool (INFRA-102..105).
for p in "$P1" "$P2" "$P3" "$P4"; do
    if [[ "$p" == "INFRA-100" || "$p" == "INFRA-101" ]]; then
        echo "  FAIL (worker picked an ACTIVE gap: $p)"
        exit 1
    fi
done
echo "  PASS (no worker picked an ACTIVE gap)"

# ── Test 2: concurrent workers with ACTIVE_GAPS don't collide ────────────────
echo "Test 2: concurrent workers with ACTIVE_GAPS pick distinct gaps"
rm -rf "$lock_dir" && mkdir -p "$lock_dir"
ACTIVE="INFRA-100 INFRA-101"
declare -a pids
for i in 1 2 3 4; do
    (
        pick=$(CHUMP_SESSION_ID="session-conc-$i" \
               GAP_JSON_FILE="$TMP/gaps.json" \
               CHUMP_LOCK_DIR="$lock_dir" \
               FLEET_PRIORITY_FILTER="P0,P1" \
               FLEET_DOMAIN_FILTER="INFRA" \
               FLEET_EFFORT_FILTER="xs,s,m" \
               EXCLUDE_RE="^$" \
               ACTIVE_GAPS="$ACTIVE" \
               WORKER_INDEX="$i" \
               python3 "$PICKER" 2>/dev/null || true)
        [[ -n "$pick" ]] && echo "$pick"
    ) > "$TMP/conc-$i.txt" &
    pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
picks_conc=()
for i in 1 2 3 4; do
    p=$(cat "$TMP/conc-$i.txt" 2>/dev/null || true)
    [[ -n "$p" ]] && picks_conc+=("$p")
done
distinct_conc=$(printf '%s\n' "${picks_conc[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$distinct_conc" == "${#picks_conc[@]}" ]]; then
    echo "  PASS (all ${#picks_conc[@]} concurrent picks distinct)"
    printf '  Claimed: %s\n' "${picks_conc[@]}"
else
    echo "  FAIL (collision detected in concurrent picks)"
    printf '  Got: %s\n' "${picks_conc[@]}"
    exit 1
fi

# ── Test 3: without ACTIVE_GAPS, stagger offset uses wrong pool size ─────────
# Documents the regression: workers 3 and 4 (offset 2,3 mod 4 = 2,3) start
# on INFRA-102 and INFRA-103, which happen to be unlocked. If top 2 are locked
# AND we don't pass ACTIVE_GAPS (pool size = 6 not 4), worker 3 offset=(3-1)%6=2
# → INFRA-102 (unlocked) and worker 4 offset=(4-1)%6=3 → INFRA-103 (unlocked),
# which still works here by coincidence. But with 4 active gaps and only 2
# unclaimed, workers 1-4 with pool=6 land on offsets 0,1,2,3 → all may fall
# through to the same unclaimed gap.
echo "Test 3: regression case — 4 active gaps, only 2 unclaimed"
rm -rf "$lock_dir" && mkdir -p "$lock_dir"
ACTIVE4="INFRA-100 INFRA-101 INFRA-102 INFRA-103"

# With ACTIVE_GAPS (post-fix): candidates=[INFRA-104, INFRA-105], workers spread
PA=$(CHUMP_SESSION_ID="s-a" GAP_JSON_FILE="$TMP/gaps.json" CHUMP_LOCK_DIR="$lock_dir" \
     FLEET_PRIORITY_FILTER="P0,P1" FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" \
     EXCLUDE_RE="^$" ACTIVE_GAPS="$ACTIVE4" WORKER_INDEX="1" python3 "$PICKER" 2>/dev/null || true)
PB=$(CHUMP_SESSION_ID="s-b" GAP_JSON_FILE="$TMP/gaps.json" CHUMP_LOCK_DIR="$lock_dir" \
     FLEET_PRIORITY_FILTER="P0,P1" FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" \
     EXCLUDE_RE="^$" ACTIVE_GAPS="$ACTIVE4" WORKER_INDEX="2" python3 "$PICKER" 2>/dev/null || true)
echo "  with ACTIVE_GAPS: worker 1 → $PA, worker 2 → $PB"
if [[ "$PA" != "$PB" && -n "$PA" && -n "$PB" ]]; then
    echo "  PASS (distinct picks with correct ACTIVE_GAPS)"
else
    echo "  FAIL (expected 2 distinct picks, got: '$PA' and '$PB')"
    exit 1
fi

echo ""
echo "All INFRA-409 stagger regression tests passed."
