#!/usr/bin/env bash
# test-pick-gap-skips-merged.sh — RESILIENT-1510
#
# cuphead worker picked RESILIENT-1497 at 07:00, 07:44, 08:21 and 08:26Z; its
# PR #4983 merged at 08:20Z. Two picks came after the merge, wasting cycles.
# Root cause: `chump gap list --json` can lag behind a just-merged PR (the
# gap-store status flip to "done"/closed_pr isn't instant), so the picker
# re-offered a gap whose work was already shipped.
#
# Fix: worker.sh scans recent origin/main commit subjects for a leading
# gap-id token (squash-merge commits are always "<GAP-ID>: ... (#NNNN)") and
# passes them to the picker as MERGED_RECENT_GAPS; the picker excludes any
# candidate in that set regardless of what the gap-store status says.
#
# AC-1: a gap with a merged PR carrying its id is not picked again (this test).
# AC-2: worker.sh computes+passes MERGED_RECENT_GAPS and logs a receipt when
#       it excludes a gap (journal receipt, asserted via wiring checks here).

set -uo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

TMP="$(mktemp -d -t pick-gap-skips-merged.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

run_picker() {
    local gaps_file="$1"; shift
    GAP_JSON_FILE="$gaps_file" \
    CHUMP_LOCK_DIR="$TMP/locks" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_REBALANCE=0 \
    WORKER_INDEX=1 \
    WORKER_ID=1 \
      "$@" python3 "$PICKER"
}

AC='the gap is fixed and tested'

cat > "$TMP/queue.json" <<JSON
[
  {"id":"RESILIENT-1497","status":"open","priority":"P1","effort":"s","domain":"RESILIENT","depends_on":"[]","acceptance_criteria":"$AC","title":"stale re-pick candidate"},
  {"id":"RESILIENT-1498","status":"open","priority":"P1","effort":"s","domain":"RESILIENT","depends_on":"[]","acceptance_criteria":"$AC","title":"real next pick"}
]
JSON

# 1. A gap whose PR merged recently (per MERGED_RECENT_GAPS) must not be
#    re-offered, even though gap-store status still says "open".
p="$(MERGED_RECENT_GAPS="RESILIENT-1497" run_picker "$TMP/queue.json")"
if [[ "$p" == "RESILIENT-1498" ]]; then
    pass "skips recently-merged gap RESILIENT-1497, offers RESILIENT-1498 instead"
else
    fail "expected RESILIENT-1498, got '$p' (RESILIENT-1497 was re-offered despite merged PR)"
fi

# 2. No over-exclusion: when MERGED_RECENT_GAPS doesn't mention the top gap,
#    it is still offered normally.
p="$(MERGED_RECENT_GAPS="RESILIENT-1498" run_picker "$TMP/queue.json")"
if [[ "$p" == "RESILIENT-1497" ]]; then
    pass "does not over-exclude: top gap still offered when it isn't in MERGED_RECENT_GAPS"
else
    fail "expected RESILIENT-1497, got '$p'"
fi

# 3. Empty/unset MERGED_RECENT_GAPS is a no-op (back-compat / offline-safe).
p="$(run_picker "$TMP/queue.json")"
if [[ "$p" == "RESILIENT-1497" ]]; then
    pass "unset MERGED_RECENT_GAPS is a no-op (normal top-priority pick)"
else
    fail "expected RESILIENT-1497 with unset MERGED_RECENT_GAPS, got '$p'"
fi

# 4. worker.sh wiring: computes merged_recent_gaps from origin/main commit
#    subjects and passes it through to the picker, with a journal receipt.
if [[ -f "$WORKER_SH" ]]; then
    if grep -q 'merged_recent_gaps=' "$WORKER_SH" \
       && grep -q 'MERGED_RECENT_GAPS="\$merged_recent_gaps"' "$WORKER_SH"; then
        pass "worker.sh computes merged_recent_gaps and passes it to the picker"
    else
        fail "worker.sh MERGED_RECENT_GAPS wiring not found"
    fi
    if grep -q 'RESILIENT-1510' "$WORKER_SH" && grep -q 'excluding recently-merged gaps' "$WORKER_SH"; then
        pass "worker.sh logs a journal receipt when excluding recently-merged gaps"
    else
        fail "worker.sh journal receipt for merged-gap exclusion not found"
    fi
else
    fail "worker.sh not found at $WORKER_SH"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
