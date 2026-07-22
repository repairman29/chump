#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-claim-diff-intersection.sh — INFRA-1763
#
# CI test for the predictive collision check in `chump claim`: intersecting
# a sibling's LIVE git diff (files actually touched, not declared paths)
# against this claim's declared --paths.
#
# Verifies:
#   1. A claim is BLOCKED without --force-overlap when a sibling worktree's
#      real git diff touches a file inside this claim's declared --paths.
#   2. kind=claim_diff_intersection_predicted is emitted to ambient.jsonl.
#   3. The same claim SUCCEEDS with --force-overlap, emitting
#      kind=claim_diff_intersection_bypassed instead.
#   4. A sibling whose diff does NOT overlap declared --paths does not block.
#   5. No sibling lease at all → not blocked.
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -z "${CHUMP_BIN:-}" ]]; then
    CANDIDATE="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ -x "$CANDIDATE" ]]; then
        CHUMP_BIN="$CANDIDATE"
    else
        echo "Building chump binary..."
        cd "$REPO_ROOT" && cargo build --bin chump -q
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
        cd "$REPO_ROOT"
    fi
fi

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

echo "=== INFRA-1763 chump claim diff-intersection tests ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.git" "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" "$FAKE_REPO/docs/gaps"

cd "$FAKE_REPO"
git init -q
git config user.email "ci@test.local"
git config user.name "CI Test"
git config commit.gpgsign false
echo "test" > README.md
mkdir -p src
echo "fn a() {}" > src/shared.rs
git add README.md src/shared.rs
git -c init.defaultBranch=main commit -q -m "init"
git branch -M main
git remote add origin "$FAKE_REPO"
cd "$REPO_ROOT"

seed_gap_db() {
    local db="$FAKE_REPO/.chump/state.db"
    local gap_id="$1"
    sqlite3 "$db" <<SQL
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT,
    title TEXT,
    status TEXT,
    priority TEXT,
    acceptance_criteria TEXT
);
CREATE TABLE IF NOT EXISTS leases (
    session_id TEXT PRIMARY KEY,
    gap_id TEXT,
    worktree TEXT,
    expires_at INTEGER
);
INSERT OR REPLACE INTO gaps(id, domain, title, status, priority, acceptance_criteria)
VALUES('$gap_id', 'INFRA', 'test gap', 'open', 'P1', 'Implement a thing in src/shared.rs.');
SQL
}

# Create a sibling worktree with real (uncommitted) edits, and register it
# in state.db's leases table with a future expiry.
make_sibling_worktree_with_edit() {
    local session="$1"
    local sibling_gap="$2"
    local edit_file="$3"
    local wt="$WORK/sibling-wt-$session"
    rm -rf "$wt"
    git -C "$FAKE_REPO" worktree add -q -b "sibling-$session" "$wt" main
    mkdir -p "$(dirname "$wt/$edit_file")"
    echo "// sibling edit" >> "$wt/$edit_file"

    local exp=$(( $(date -u +%s) + 14400 ))
    sqlite3 "$FAKE_REPO/.chump/state.db" \
        "INSERT OR REPLACE INTO leases(session_id, gap_id, worktree, expires_at) VALUES('$session', '$sibling_gap', '$wt', $exp);"
}

run_claim() {
    local gap_id="$1"
    shift
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WORK/worktrees" \
    CHUMP_REMOTE="origin" \
    CHUMP_BASE_BRANCH="main" \
    "$CHUMP_BIN" claim "$gap_id" \
        --skip-doctor --skip-import \
        "$@" 2>&1
}

mkdir -p "$WORK/worktrees"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Check 1+2: blocked + event emitted when sibling's real diff overlaps ─────
echo "Check 1: claim blocked without --force-overlap (sibling's live diff overlaps declared --paths)"

rm -f "$FAKE_REPO/.chump/state.db" "$AMBIENT"
seed_gap_db "INFRA-DTEST01"
make_sibling_worktree_with_edit "sibling-session-1" "INFRA-OTHER01" "src/shared.rs"
rm -rf "$WORK/worktrees/chump-infra-dtest01"

set +e
CLAIM_OUT=$(run_claim "INFRA-DTEST01" --paths "src/shared.rs" 2>&1)
CLAIM_RC=$?
set -e

if [[ $CLAIM_RC -eq 16 ]]; then
    ok "claim exited 16 (diff-intersection block) without --force-overlap"
elif [[ $CLAIM_RC -ne 0 ]]; then
    if echo "$CLAIM_OUT" | grep -qi "diff.intersection\|predicted collision\|force.overlap"; then
        ok "claim blocked with diff-intersection message (rc=$CLAIM_RC)"
    else
        fail "claim exited $CLAIM_RC but no diff-intersection message (output: $CLAIM_OUT)"
    fi
else
    fail "claim should have been blocked but exited 0 (output: $CLAIM_OUT)"
fi

if echo "$CLAIM_OUT" | grep -qi "INFRA-1763\|diff.intersection\|predicted collision"; then
    ok "diff-intersection warning message printed"
else
    fail "expected diff-intersection warning in output, got: $CLAIM_OUT"
fi

echo
echo "Check 2: kind=claim_diff_intersection_predicted emitted to ambient.jsonl"
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_diff_intersection_predicted"' "$AMBIENT"; then
    ok "claim_diff_intersection_predicted event present"
else
    fail "claim_diff_intersection_predicted event NOT found (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi
if grep -q '"claim_gap":"INFRA-DTEST01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct claim_gap field"
else
    fail "ambient event missing claim_gap field"
fi
if grep -q '"overlap_paths"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has overlap_paths field"
else
    fail "ambient event missing overlap_paths field"
fi

# ── Check 3: claim succeeds with --force-overlap, bypass event fires ─────────
echo
echo "Check 3: claim succeeds with --force-overlap"

rm -rf "$WORK/worktrees/chump-infra-dtest01"
rm -f "$AMBIENT"

set +e
FORCE_OUT=$(run_claim "INFRA-DTEST01" --paths "src/shared.rs" --force-overlap 2>&1)
FORCE_RC=$?
set -e

if [[ $FORCE_RC -eq 16 ]]; then
    fail "claim exited 16 even with --force-overlap — should have proceeded"
else
    ok "claim did NOT exit 16 with --force-overlap (rc=$FORCE_RC)"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_diff_intersection_bypassed"' "$AMBIENT"; then
    ok "claim_diff_intersection_bypassed event emitted with --force-overlap"
else
    fail "claim_diff_intersection_bypassed event NOT emitted when --force-overlap used"
fi

# ── Check 4: sibling diff does not overlap declared paths → not blocked ──────
echo
echo "Check 4: sibling diff touches an unrelated file → not blocked"

rm -f "$FAKE_REPO/.chump/state.db" "$AMBIENT"
seed_gap_db "INFRA-DTEST02"
make_sibling_worktree_with_edit "sibling-session-2" "INFRA-OTHER02" "src/unrelated.rs"
rm -rf "$WORK/worktrees/chump-infra-dtest02"

set +e
NOOVERLAP_OUT=$(run_claim "INFRA-DTEST02" --paths "src/shared.rs" 2>&1)
NOOVERLAP_RC=$?
set -e

if [[ $NOOVERLAP_RC -eq 16 ]]; then
    fail "claim blocked (rc=16) when sibling diff does not overlap declared paths"
else
    ok "claim not blocked (rc=$NOOVERLAP_RC) when sibling diff is disjoint"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_diff_intersection_predicted"' "$AMBIENT"; then
    fail "spurious claim_diff_intersection_predicted event for disjoint diff"
else
    ok "no spurious diff-intersection event for disjoint diff"
fi

# ── Check 5: no sibling lease at all → not blocked ────────────────────────────
echo
echo "Check 5: no sibling lease → claim not blocked"

rm -f "$FAKE_REPO/.chump/state.db" "$AMBIENT"
seed_gap_db "INFRA-DTEST03"
rm -rf "$WORK/worktrees/chump-infra-dtest03"

set +e
NOSIBLING_OUT=$(run_claim "INFRA-DTEST03" --paths "src/shared.rs" 2>&1)
NOSIBLING_RC=$?
set -e

if [[ $NOSIBLING_RC -eq 16 ]]; then
    fail "claim blocked (rc=16) when no sibling lease present"
else
    ok "claim not blocked (rc=$NOSIBLING_RC) with no sibling lease"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
