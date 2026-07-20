#!/usr/bin/env bash
# INFRA-1954: regression — `chump gap reserve` must not hand out an ID that
# already appears in git history, even when the live registry (state.db)
# has no record of it (row purged, or a fresh/reset state.db). Observed 4x
# in the 2026-05-25 Cold Water cycle: META-103, INFRA-1953, INFRA-1955,
# INFRA-1957 were all re-assigned to shipped-and-forgotten gaps.
#
# Run from repo root: bash scripts/ci/test-gap-reserve-no-reuse.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

SANDBOX="$TMPROOT/sandbox"
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/.chump-locks"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"

reserve_in_sandbox() {
    local title="$1"
    CHUMP_HOME="$SANDBOX" \
    CHUMP_REPO="$SANDBOX" \
    CHUMP_SESSION_ID="test-no-reuse-$$" \
    CHUMP_RESERVE_VERIFY=0 \
    FLEET_029_AMBIENT_GLANCE_SKIP=1 \
    CHUMP_DISABLE_OFFLINE_CHECK=1 \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    CHUMP_PILLAR_BALANCE_DISABLE=1 \
    chump gap reserve --domain TESTDUP --title "$title" --quiet --json --no-evidence-required 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

# 1. Reserve a dummy gap; it should land on TESTDUP-001.
first_id=$(reserve_in_sandbox "dummy gap one")
if [ "$first_id" = "TESTDUP-001" ]; then
    pass "first reserve → TESTDUP-001 (got $first_id)"
else
    fail "expected TESTDUP-001, got $first_id"
fi

# 2. Simulate the gap shipping: commit referencing its ID (as gap-ship /
#    bot-merge.sh do in the real PR-close commit), then simulate the row
#    dropping out of the live registry — a fresh/reset state.db, or a
#    purged row — by deleting it and rewinding the domain counter.
echo "shipped work" > "$SANDBOX/shipped.txt"
git -C "$SANDBOX" add shipped.txt
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "feat(TESTDUP-001): dummy gap one shipped"

sqlite3 "$SANDBOX/.chump/state.db" "DELETE FROM gaps WHERE id='TESTDUP-001';"
sqlite3 "$SANDBOX/.chump/state.db" "UPDATE gap_counters SET next_num=1 WHERE domain='TESTDUP';"

# 3. Reserve again. The live registry now looks like TESTDUP-001 was never
#    used (row gone, counter rewound) — but git history still references
#    it. The guard must skip it rather than reissue it.
second_id=$(reserve_in_sandbox "dummy gap two")
if [ "$second_id" != "TESTDUP-001" ] && [ -n "$second_id" ]; then
    pass "second reserve did not reuse TESTDUP-001 (got $second_id)"
else
    fail "expected a non-TESTDUP-001 ID, got '$second_id'"
fi

# 4. Sanity: the skip must be logged to ambient.jsonl for audit.
if grep -q '"kind":"gap_reserve_git_history_duplicate"' "$SANDBOX/.chump-locks/ambient.jsonl" 2>/dev/null; then
    pass "gap_reserve_git_history_duplicate emitted to ambient.jsonl"
else
    fail "expected gap_reserve_git_history_duplicate in ambient.jsonl"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
