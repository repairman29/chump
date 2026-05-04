#!/bin/bash
# test-pick-and-claim-atomic.sh — INFRA-415 atomicity test.
#
# Verify that concurrent workers cannot race on the same gap. This test
# spawns N concurrent pickers on a list of M gaps and verifies:
# 1. All claimed gaps are distinct
# 2. No two workers claim the same gap
# 3. All available gaps are claimed if N >= M
#
# This exercises the atomic file-based claiming in _pick_and_claim_gap.py.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Test data: 4 P1 gaps
cat >"$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-100","domain":"INFRA","priority":"P1","effort":"xs","created_at":1000,"depends_on":"","status":"open"},
  {"id":"INFRA-101","domain":"INFRA","priority":"P1","effort":"xs","created_at":1001,"depends_on":"","status":"open"},
  {"id":"INFRA-102","domain":"INFRA","priority":"P1","effort":"s", "created_at":1002,"depends_on":"","status":"open"},
  {"id":"INFRA-103","domain":"INFRA","priority":"P1","effort":"s", "created_at":1003,"depends_on":"","status":"open"}
]
EOF

lock_dir="$TMP/.chump-locks"
mkdir -p "$lock_dir"

# ── Test 1: Sequential claiming (sanity check) ────────────────────────────────
echo "Test 1: Sequential picks claim distinct gaps"
picks=()
for i in 1 2 3 4; do
    pick=$(CHUMP_SESSION_ID="session-seq-$i" \
            GAP_JSON_FILE="$TMP/gaps.json" \
            CHUMP_LOCK_DIR="$lock_dir" \
            FLEET_PRIORITY_FILTER="P0,P1" \
            FLEET_DOMAIN_FILTER="INFRA" \
            FLEET_EFFORT_FILTER="xs,s,m" \
            EXCLUDE_RE="^$" \
            WORKER_INDEX="$i" \
            python3 "$PICKER" 2>/dev/null || true)
    if [[ -n "$pick" ]]; then
        picks+=("$pick")
        echo "  session-seq-$i claimed: $pick"
    fi
done

distinct=$(printf '%s\n' "${picks[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$distinct" == "${#picks[@]}" ]]; then
    echo "  PASS (all ${#picks[@]} picks are distinct)"
else
    echo "  FAIL (claimed $distinct distinct gaps out of ${#picks[@]} picks)"
    printf '  Claimed: %s\n' "${picks[@]}"
    exit 1
fi

# ── Test 2: Concurrent claiming (race condition test) ────────────────────────
echo "Test 2: Concurrent picks don't collide"
rm -rf "$lock_dir"
mkdir -p "$lock_dir"

# Spawn 4 concurrent pickers, all trying to claim from the same gap list.
# Each runs in the background with its own session ID.
declare -a pids
declare -a picks_concurrent
for i in 1 2 3 4; do
    (
        pick=$(CHUMP_SESSION_ID="session-conc-$i" \
                GAP_JSON_FILE="$TMP/gaps.json" \
                CHUMP_LOCK_DIR="$lock_dir" \
                FLEET_PRIORITY_FILTER="P0,P1" \
                FLEET_DOMAIN_FILTER="INFRA" \
                FLEET_EFFORT_FILTER="xs,s,m" \
                EXCLUDE_RE="^$" \
                WORKER_INDEX="$i" \
                python3 "$PICKER" 2>/dev/null || true)
        if [[ -n "$pick" ]]; then
            echo "$pick"
        fi
    ) > "$TMP/pick-$i.txt" &
    pids+=($!)
done

# Wait for all to finish
for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# Collect results
picks_concurrent=()
for i in 1 2 3 4; do
    if [[ -f "$TMP/pick-$i.txt" ]]; then
        pick=$(cat "$TMP/pick-$i.txt")
        if [[ -n "$pick" ]]; then
            picks_concurrent+=("$pick")
        fi
    fi
done

distinct_conc=$(printf '%s\n' "${picks_concurrent[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$distinct_conc" == "${#picks_concurrent[@]}" ]]; then
    echo "  PASS (all ${#picks_concurrent[@]} concurrent picks are distinct)"
    printf '  Claimed: %s\n' "${picks_concurrent[@]}"
else
    echo "  FAIL (concurrent picks collided!)"
    printf '  Expected distinct, got: %s\n' "${picks_concurrent[@]}"
    exit 1
fi

# ── Test 3: Fifth pick gets nothing (all gaps claimed) ─────────────────────────
echo "Test 3: No gap left when all are claimed"
pick_fifth=$(CHUMP_SESSION_ID="session-conc-5" \
             GAP_JSON_FILE="$TMP/gaps.json" \
             CHUMP_LOCK_DIR="$lock_dir" \
             FLEET_PRIORITY_FILTER="P0,P1" \
             FLEET_DOMAIN_FILTER="INFRA" \
             FLEET_EFFORT_FILTER="xs,s,m" \
             EXCLUDE_RE="^$" \
             WORKER_INDEX="5" \
             python3 "$PICKER" 2>/dev/null || true)
if [[ -z "$pick_fifth" ]]; then
    echo "  PASS (no gap available for 5th picker)"
else
    echo "  FAIL (5th picker should get nothing, got: $pick_fifth)"
    exit 1
fi

echo ""
echo "All atomic picker tests passed."
