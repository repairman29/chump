#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-claim-path-overlap.sh — INFRA-3798 (INFRA-2434 slice)
#
# CI smoke test for the claim-time file-level path overlap check in
# `chump claim`.
#
# Verifies:
#   1. A claim with --paths pointing at a file present in another open PR's
#      file list is refused (non-zero exit) with the redirect message
#      ("(a) coordinate ... (b) wait ... (c) --allow-overlap ...").
#   2. kind=claim_path_overlap_blocked is emitted to ambient.jsonl with the
#      expected fields.
#   3. A claim with --paths pointing at a DIFFERENT file (no overlap)
#      succeeds (does not hit the overlap block).
#   4. --allow-overlap bypasses the block (still audit-logged).
#
# A fake `gh` shim on PATH stands in for GitHub — no network/auth required.
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

echo "=== INFRA-3798 chump claim path-overlap tests ==="
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
git add README.md
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
VALUES('$gap_id', 'INFRA', 'test gap', 'open', 'P1', 'test AC');
SQL
}

# ── Fake `gh` shim: models a mock open (draft) PR #9001 (gap INFRA-9001)
# that has already changed src/overlap_target.rs. Any other `gh pr list`
# shape used by other claim-time gates (fuzzy-match, dup-PR search) gets an
# empty result so those gates stay quiet; `gh api ...` calls (open_pr_info /
# closed_pr_for_branch) return nothing so no PR is found on the claim branch.
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
args="$*"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    if [[ "$args" == *"number,title,files"* ]]; then
        cat <<'JSON'
[{"number":9001,"title":"INFRA-9001: unrelated work in flight","files":[{"path":"src/overlap_target.rs"}]}]
JSON
        exit 0
    fi
    echo "[]"
    exit 0
fi
if [[ "$1" == "api" ]]; then
    exit 0
fi
exit 1
SHIM
chmod +x "$FAKE_BIN/gh"

mkdir -p "$WORK/worktrees"

run_claim() {
    local gap_id="$1"
    shift
    PATH="$FAKE_BIN:$PATH" \
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WORK/worktrees" \
    CHUMP_REMOTE="origin" \
    CHUMP_BASE_BRANCH="main" \
    "$CHUMP_BIN" claim "$gap_id" \
        --skip-doctor --skip-import \
        "$@" 2>&1
}

AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Check 1: claim with an overlapping path is BLOCKED ────────────────────
echo "Check 1: claim blocked when --paths overlaps an open PR's file list"

seed_gap_db "INFRA-TEST01"
rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
OUT1=$(run_claim "INFRA-TEST01" --paths "src/overlap_target.rs")
RC1=$?
set -e

if [[ $RC1 -ne 0 ]]; then
    ok "claim exited non-zero (rc=$RC1) for overlapping path"
else
    fail "claim should have been blocked (overlap) but exited 0"
fi

if echo "$OUT1" | grep -qi "paths overlap with open PR #9001"; then
    ok "redirect message names blocking PR #9001"
else
    fail "expected 'paths overlap with open PR #9001' in output, got: $OUT1"
fi

if echo "$OUT1" | grep -qi "gap INFRA-9001"; then
    ok "redirect message names blocking gap INFRA-9001"
else
    fail "expected 'gap INFRA-9001' in output, got: $OUT1"
fi

if echo "$OUT1" | grep -qi "coordinate with #9001 author" \
    && echo "$OUT1" | grep -qi "wait for #9001 to land" \
    && echo "$OUT1" | grep -qi -- "--allow-overlap to proceed anyway"; then
    ok "redirect message lists all three options (a)/(b)/(c)"
else
    fail "expected all three redirect options in output, got: $OUT1"
fi

# ── Check 2: kind=claim_path_overlap_blocked emitted with expected fields ──
echo
echo "Check 2: claim_path_overlap_blocked emitted to ambient.jsonl"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT"; then
    ok "claim_path_overlap_blocked event present in ambient.jsonl"
else
    fail "claim_path_overlap_blocked event NOT found (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"claimed_gap":"INFRA-TEST01"' "$AMBIENT" 2>/dev/null; then
    ok "event has correct claimed_gap field"
else
    fail "event missing/incorrect claimed_gap field"
fi

if grep -q '"blocking_pr":9001' "$AMBIENT" 2>/dev/null; then
    ok "event has correct blocking_pr field"
else
    fail "event missing/incorrect blocking_pr field"
fi

if grep -q '"blocking_gap":"INFRA-9001"' "$AMBIENT" 2>/dev/null; then
    ok "event has correct blocking_gap field"
else
    fail "event missing/incorrect blocking_gap field"
fi

if grep -q '"overlapping_paths":\["src/overlap_target.rs"\]' "$AMBIENT" 2>/dev/null; then
    ok "event has correct overlapping_paths field"
else
    fail "event missing/incorrect overlapping_paths field"
fi

# ── Check 3: claim with a DIFFERENT path succeeds (no overlap) ────────────
echo
echo "Check 3: claim with a non-overlapping path is not blocked"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
OUT2=$(run_claim "INFRA-TEST01" --paths "src/some_other_file.rs")
RC2=$?
set -e

if echo "$OUT2" | grep -qi "paths overlap with open PR"; then
    fail "claim was blocked for a non-overlapping path: $OUT2"
else
    ok "claim not blocked (rc=$RC2) for non-overlapping path"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT"; then
    fail "spurious claim_path_overlap_blocked event for non-overlapping path"
else
    ok "no spurious claim_path_overlap_blocked event for non-overlapping path"
fi

# ── Check 4: --allow-overlap bypasses the block (still audit-logged) ──────
echo
echo "Check 4: --allow-overlap proceeds past the block"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
OUT3=$(run_claim "INFRA-TEST01" --paths "src/overlap_target.rs" --allow-overlap)
RC3=$?
set -e

if echo "$OUT3" | grep -qi -- "--allow-overlap set; proceeding despite overlap"; then
    ok "--allow-overlap proceed message printed"
else
    fail "expected --allow-overlap proceed message, got: $OUT3"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT"; then
    ok "claim_path_overlap_blocked still emitted with --allow-overlap (audit trail preserved)"
else
    fail "claim_path_overlap_blocked NOT emitted despite --allow-overlap"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
