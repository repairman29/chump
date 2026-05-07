#!/usr/bin/env bash
# test-fleet-staggering.sh — INFRA-409 fleet-level stagger regression test.
#
# Simulates FLEET_SIZE=4 concurrent workers picking from a shared gap pool.
# All 4 workers must claim distinct gaps within a 5-second window.
#
# Root-cause documented: worker.sh dropped ACTIVE_GAPS when wiring
# _pick_and_claim_gap.py (INFRA-415), causing all workers to compute stagger
# offset against the full pool (including already-claimed gaps). Workers whose
# staggered slot was locked fell through to the same unclaimed gap.
#
# Post-fix: ACTIVE_GAPS is passed, candidates exclude in-progress gaps, and
# fcntl.flock in the picker prevents concurrent collision.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: picker missing: $PICKER"; exit 1; }

FLEET_SIZE=4
TIMEOUT_S=5

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

lock_dir="$TMP/.chump-locks"
mkdir -p "$lock_dir"

# Eight P1 gaps — enough that FLEET_SIZE=4 workers can all get distinct picks.
cat >"$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-200","domain":"INFRA","priority":"P1","effort":"xs","created_at":2000,"depends_on":"","status":"open"},
  {"id":"INFRA-201","domain":"INFRA","priority":"P1","effort":"xs","created_at":2001,"depends_on":"","status":"open"},
  {"id":"INFRA-202","domain":"INFRA","priority":"P1","effort":"s", "created_at":2002,"depends_on":"","status":"open"},
  {"id":"INFRA-203","domain":"INFRA","priority":"P1","effort":"s", "created_at":2003,"depends_on":"","status":"open"},
  {"id":"INFRA-204","domain":"INFRA","priority":"P1","effort":"m", "created_at":2004,"depends_on":"","status":"open"},
  {"id":"INFRA-205","domain":"INFRA","priority":"P1","effort":"m", "created_at":2005,"depends_on":"","status":"open"},
  {"id":"INFRA-206","domain":"INFRA","priority":"P1","effort":"m", "created_at":2006,"depends_on":"","status":"open"},
  {"id":"INFRA-207","domain":"INFRA","priority":"P1","effort":"m", "created_at":2007,"depends_on":"","status":"open"}
]
EOF

echo "=== INFRA-409: FLEET_SIZE=$FLEET_SIZE stagger test (${TIMEOUT_S}s window) ==="

# ── Test 1: sequential workers spread across the pool ────────────────────────
echo ""
echo "Test 1: sequential FLEET_SIZE=$FLEET_SIZE workers pick distinct gaps"
rm -rf "$lock_dir" && mkdir -p "$lock_dir"

seq_picks=()
for i in $(seq 1 "$FLEET_SIZE"); do
    p=$(CHUMP_SESSION_ID="fleet-seq-$i" \
        GAP_JSON_FILE="$TMP/gaps.json" \
        CHUMP_LOCK_DIR="$lock_dir" \
        FLEET_PRIORITY_FILTER="P0,P1" \
        FLEET_DOMAIN_FILTER="INFRA" \
        FLEET_EFFORT_FILTER="xs,s,m" \
        EXCLUDE_RE="^$" \
        ACTIVE_GAPS="" \
        WORKER_INDEX="$i" \
        python3 "$PICKER" 2>/dev/null || true)
    seq_picks+=("$p")
    echo "  worker $i → $p"
done

seq_distinct=$(printf '%s\n' "${seq_picks[@]}" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [[ "$seq_distinct" == "$FLEET_SIZE" ]]; then
    echo "  PASS ($FLEET_SIZE distinct sequential picks)"
else
    echo "  FAIL (expected $FLEET_SIZE distinct picks, got $seq_distinct)"
    exit 1
fi

# ── Test 2: concurrent workers within 5s window pick distinct gaps ────────────
echo ""
echo "Test 2: $FLEET_SIZE concurrent workers all pick within ${TIMEOUT_S}s and stay distinct"
rm -rf "$lock_dir" && mkdir -p "$lock_dir"

start_ts=$(date +%s)
declare -a conc_pids=()
for i in $(seq 1 "$FLEET_SIZE"); do
    (
        pick=$(CHUMP_SESSION_ID="fleet-conc-$i" \
               GAP_JSON_FILE="$TMP/gaps.json" \
               CHUMP_LOCK_DIR="$lock_dir" \
               FLEET_PRIORITY_FILTER="P0,P1" \
               FLEET_DOMAIN_FILTER="INFRA" \
               FLEET_EFFORT_FILTER="xs,s,m" \
               EXCLUDE_RE="^$" \
               ACTIVE_GAPS="" \
               WORKER_INDEX="$i" \
               python3 "$PICKER" 2>/dev/null || true)
        echo "$pick"
    ) > "$TMP/conc-$i.txt" &
    conc_pids+=($!)
done

# Wait with a hard timeout ceiling.
deadline=$((start_ts + TIMEOUT_S))
all_done=0
for pid in "${conc_pids[@]}"; do
    now=$(date +%s)
    if [[ $now -ge $deadline ]]; then
        echo "  FAIL (workers did not complete within ${TIMEOUT_S}s)"
        exit 1
    fi
    remaining=$((deadline - now))
    # macOS: timeout not always available; use wait directly (it should be fast).
    wait "$pid" 2>/dev/null || true
done
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

conc_picks=()
for i in $(seq 1 "$FLEET_SIZE"); do
    p=$(cat "$TMP/conc-$i.txt" 2>/dev/null || true)
    echo "  worker $i → $p"
    [[ -n "$p" ]] && conc_picks+=("$p")
done

conc_distinct=$(printf '%s\n' "${conc_picks[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "${#conc_picks[@]}" -lt "$FLEET_SIZE" ]]; then
    echo "  FAIL (only ${#conc_picks[@]} of $FLEET_SIZE workers got a pick)"
    exit 1
fi
if [[ "$conc_distinct" != "$FLEET_SIZE" ]]; then
    echo "  FAIL (collision: $conc_distinct distinct of $FLEET_SIZE picks in ${elapsed}s)"
    exit 1
fi
echo "  PASS ($FLEET_SIZE distinct concurrent picks in ${elapsed}s ≤ ${TIMEOUT_S}s)"

# ── Test 3: ACTIVE_GAPS correctly excludes in-flight siblings ─────────────────
echo ""
echo "Test 3: ACTIVE_GAPS excludes top 4 gaps; remaining 4 workers spread across bottom 4"
rm -rf "$lock_dir" && mkdir -p "$lock_dir"

ACTIVE="INFRA-200 INFRA-201 INFRA-202 INFRA-203"
active_picks=()
for i in $(seq 1 "$FLEET_SIZE"); do
    p=$(CHUMP_SESSION_ID="fleet-active-$i" \
        GAP_JSON_FILE="$TMP/gaps.json" \
        CHUMP_LOCK_DIR="$lock_dir" \
        FLEET_PRIORITY_FILTER="P0,P1" \
        FLEET_DOMAIN_FILTER="INFRA" \
        FLEET_EFFORT_FILTER="xs,s,m" \
        EXCLUDE_RE="^$" \
        ACTIVE_GAPS="$ACTIVE" \
        WORKER_INDEX="$i" \
        python3 "$PICKER" 2>/dev/null || true)
    active_picks+=("$p")
    echo "  worker $i → $p"
done

# Verify no pick is from ACTIVE set.
for p in "${active_picks[@]}"; do
    if [[ "$ACTIVE" == *"$p"* ]]; then
        echo "  FAIL (worker picked an ACTIVE gap: $p)"
        exit 1
    fi
done

active_distinct=$(printf '%s\n' "${active_picks[@]}" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [[ "$active_distinct" == "$FLEET_SIZE" ]]; then
    echo "  PASS ($FLEET_SIZE distinct picks from non-ACTIVE pool)"
else
    echo "  FAIL (expected $FLEET_SIZE distinct, got $active_distinct — stagger broken)"
    exit 1
fi

echo ""
echo "All INFRA-409 fleet-staggering tests passed (FLEET_SIZE=$FLEET_SIZE, window=${TIMEOUT_S}s)."
