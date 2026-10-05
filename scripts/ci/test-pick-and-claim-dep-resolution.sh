#!/usr/bin/env bash
# test-pick-and-claim-dep-resolution.sh — RESILIENT-1114 regression test.
#
# _pick_gap.py (canonical) resolves depends_on via INFRA-398: a gap whose
# deps are all status=done stays pickable. _pick_and_claim_gap.py used to
# coarse-skip ANY gap with a non-empty depends_on, regardless of whether
# those deps were satisfied — silently dropping dep-satisfied gaps from the
# production picker+claimer. This test asserts the claimer now mirrors the
# canonical dep-resolution behavior.
#
# Network-free: exercises _pick_and_claim_gap.py directly with a synthetic
# candidate set + temp lock dir.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_picker() {
    local gaps_file="$1" session="$2" worker_idx="$3" lock_dir="$4"
    CHUMP_SESSION_ID="$session" \
    GAP_JSON_FILE="$gaps_file" \
    CHUMP_LOCK_DIR="$lock_dir" \
    FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" \
    FLEET_EFFORT_FILTER="xs,s,m" \
    FLEET_MODEL="haiku" \
    EXCLUDE_RE="^$" \
    WORKER_INDEX="$worker_idx" \
    python3 "$PICKER" 2>/dev/null || true
}

# ── Test 1: gap with an all-done depends_on stays pickable ───────────────────
echo "Test 1: gap whose dep is status=done is returned by the claimer picker"
cat >"$TMP/gaps-done.json" <<'EOF'
[
  {"id":"INFRA-900","domain":"INFRA","priority":"P1","effort":"s","created_at":1000,"depends_on":"[\"INFRA-899\"]","status":"open"},
  {"id":"INFRA-899","domain":"INFRA","priority":"P1","effort":"s","created_at":900,"depends_on":"","status":"done"}
]
EOF
lock_dir_1="$TMP/locks-1"
mkdir -p "$lock_dir_1"
pick=$(run_picker "$TMP/gaps-done.json" "session-1" 1 "$lock_dir_1")
if [[ "$pick" == "INFRA-900" ]]; then
    echo "  PASS (claimed INFRA-900 despite non-empty depends_on)"
else
    echo "  FAIL (expected INFRA-900, got: '$pick')"
    exit 1
fi

# ── Test 2: gap with an unresolved (open, not done) dep stays unpickable ─────
echo "Test 2: gap whose dep is still open is NOT returned"
cat >"$TMP/gaps-open.json" <<'EOF'
[
  {"id":"INFRA-902","domain":"INFRA","priority":"P1","effort":"s","created_at":1000,"depends_on":"[\"INFRA-901\"]","status":"open"},
  {"id":"INFRA-901","priority":"P1","domain":"MISC","effort":"s","created_at":900,"depends_on":"","status":"open"}
]
EOF
lock_dir_2="$TMP/locks-2"
mkdir -p "$lock_dir_2"
pick=$(run_picker "$TMP/gaps-open.json" "session-2" 1 "$lock_dir_2")
if [[ "$pick" != "INFRA-902" ]]; then
    echo "  PASS (INFRA-902 correctly withheld: unresolved dep)"
else
    echo "  FAIL (INFRA-902 should not be pickable while INFRA-901 is open)"
    exit 1
fi

# ── Test 3: dep satisfied via ACTIVE_GAPS (claimed by a sibling this cycle) ──
echo "Test 3: gap whose dep is in ACTIVE_GAPS (sibling-claimed) stays pickable"
cat >"$TMP/gaps-active.json" <<'EOF'
[
  {"id":"INFRA-904","domain":"INFRA","priority":"P1","effort":"s","created_at":1000,"depends_on":"[\"INFRA-903\"]","status":"open"}
]
EOF
lock_dir_3="$TMP/locks-3"
mkdir -p "$lock_dir_3"
pick=$(CHUMP_SESSION_ID="session-3" \
        GAP_JSON_FILE="$TMP/gaps-active.json" \
        CHUMP_LOCK_DIR="$lock_dir_3" \
        FLEET_PRIORITY_FILTER="P0,P1" \
        FLEET_DOMAIN_FILTER="INFRA" \
        FLEET_EFFORT_FILTER="xs,s,m" \
        FLEET_MODEL="haiku" \
        EXCLUDE_RE="^$" \
        ACTIVE_GAPS="INFRA-903" \
        WORKER_INDEX="1" \
        python3 "$PICKER" 2>/dev/null || true)
if [[ "$pick" == "INFRA-904" ]]; then
    echo "  PASS (claimed INFRA-904; dep satisfied via ACTIVE_GAPS)"
else
    echo "  FAIL (expected INFRA-904, got: '$pick')"
    exit 1
fi

echo ""
echo "All dep-resolution picker+claimer tests passed."
