#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-claim-path-overlap.sh — INFRA-3798
#
# CI test for the claim-time file-level path overlap check against OPEN PRs'
# changed-file lists (`chump claim <GAP-ID> --paths ...`).
#
# Verifies:
#   1. A claim whose --paths intersects an open PR's changed-file list is
#      refused (non-zero exit) with a diagnostic naming the PR#, the gap it
#      belongs to, the overlapping paths, and the --allow-overlap escape hatch.
#   2. kind=claim_path_overlap_blocked is emitted to ambient.jsonl with the
#      required fields.
#   3. A claim whose --paths does NOT intersect any open PR's files succeeds
#      (not blocked by this check).
#   4. --allow-overlap lets the claim proceed past the block (event still
#      emitted for audit).
#
# Mocks the `gh` CLI via a PATH shim so the test runs offline / unauthenticated.
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
        (cd "$REPO_ROOT" && cargo build --bin chump -q)
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
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
git remote add origin https://github.com/test-owner/test-repo.git
cd "$REPO_ROOT"

seed_gap_db() {
    local db="$FAKE_REPO/.chump/state.db"
    local gap_id="$1"
    local ac_text="$2"
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
VALUES('$gap_id', 'INFRA', 'test gap', 'open', 'P1', '$ac_text');
SQL
}

# PATH-shim `gh`: always returns one synthetic open PR (#4242, gap
# INFRA-9999) touching `shared/hot.sh`. Any query for our OWN claim
# branch's PR (the 5b stomp-check) returns empty so that gate never fires.
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
    *"pulls?state=open&head="*)
        exit 0
        ;;
    *"pulls?state=open&per_page=100"*)
        printf '4242\tfix(INFRA-9999): unrelated shared work\n'
        exit 0
        ;;
    *"pulls/4242/files?per_page=100"*)
        printf 'shared/hot.sh\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"

run_claim() {
    local gap_id="$1"
    shift
    PATH="$SHIMDIR:$PATH" \
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

# ── Check 1: claim BLOCKED when --paths overlaps open PR #4242's files ───────
echo "Check 1: claim blocked when --paths overlaps an open PR's files"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-OVERLAP01" "Touch the shared hot script."
rm -rf "$WORK/worktrees/chump-infra-overlap01"
rm -f "$AMBIENT"

set +e
OUT=$(run_claim "INFRA-OVERLAP01" --paths shared/hot.sh)
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
    ok "claim exited non-zero (rc=$RC) when --paths overlaps open PR"
else
    fail "claim should have been blocked but exited 0: $OUT"
fi

for needle in "PR #4242" "INFRA-9999" "shared/hot.sh" "--allow-overlap"; do
    if echo "$OUT" | grep -qF -- "$needle"; then
        ok "diagnostic mentions '$needle'"
    else
        fail "diagnostic missing '$needle' — got: $OUT"
    fi
done

# ── Check 2: ambient event emitted with required fields ───────────────────────
echo
echo "Check 2: kind=claim_path_overlap_blocked emitted to ambient.jsonl"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT"; then
    ok "claim_path_overlap_blocked event present in ambient.jsonl"
else
    fail "claim_path_overlap_blocked event NOT found (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

for field in '"claimed_gap":"INFRA-OVERLAP01"' '"blocking_pr":4242' '"blocking_gap":"INFRA-9999"' '"overlapping_paths"'; do
    if grep -qF "$field" "$AMBIENT" 2>/dev/null; then
        ok "ambient event has $field"
    else
        fail "ambient event missing $field"
    fi
done

# ── Check 3: claim with a DIFFERENT file succeeds (not blocked) ──────────────
echo
echo "Check 3: claim with non-overlapping --paths is not blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-OVERLAP02" "Touch an unrelated file."
rm -rf "$WORK/worktrees/chump-infra-overlap02"
rm -f "$AMBIENT"

set +e
OUT2=$(run_claim "INFRA-OVERLAP02" --paths src/unrelated.rs)
RC2=$?
set -e

if echo "$OUT2" | grep -q "paths overlap with open PR"; then
    fail "claim wrongly blocked for non-overlapping path: $OUT2"
else
    ok "claim not blocked by path-overlap check (rc=$RC2) for non-overlapping path"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT"; then
    fail "spurious claim_path_overlap_blocked event for non-overlapping path"
else
    ok "no spurious claim_path_overlap_blocked event for non-overlapping path"
fi

# ── Check 4: --allow-overlap lets the claim proceed past the block ──────────
echo
echo "Check 4: --allow-overlap proceeds despite overlap (event still emitted)"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-OVERLAP03" "Touch the shared hot script again."
rm -rf "$WORK/worktrees/chump-infra-overlap03"
rm -f "$AMBIENT"

set +e
OUT3=$(run_claim "INFRA-OVERLAP03" --paths shared/hot.sh --allow-overlap)
RC3=$?
set -e

if echo "$OUT3" | grep -qi "allow-overlap.*proceeding\|proceeding.*allow-overlap"; then
    ok "--allow-overlap proceed message printed"
else
    if echo "$OUT3" | grep -q "paths overlap with open PR"; then
        fail "claim still blocked despite --allow-overlap: $OUT3"
    else
        ok "claim moved past path-overlap block with --allow-overlap (rc=$RC3)"
    fi
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT"; then
    ok "claim_path_overlap_blocked event emitted even with --allow-overlap (audit trail)"
else
    fail "claim_path_overlap_blocked event NOT emitted when --allow-overlap used"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
