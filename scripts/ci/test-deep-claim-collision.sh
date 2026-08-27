#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-deep-claim-collision.sh — INFRA-1604
#
# CI test for the deep lease path-set collision check in `chump claim`:
# the structural successor to INFRA-1394's 5-hot-file AC-text heuristic.
#
# Verifies:
#   1. A claim whose --paths glob-overlaps a sibling lease's declared paths[]
#      is blocked WITHOUT --force-overlap (exit 16)
#   2. The same claim SUCCEEDS with --force-overlap
#   3. kind=lease_path_collision is emitted to ambient.jsonl in both cases,
#      with claim_gap/sibling_gap/sibling_session/overlap_paths/paths_count
#   4. Directory-prefix overlap ('docs/' overlaps 'docs/gaps/X.yaml') is detected
#   5. A claim whose --paths do NOT overlap any of 3 sibling leases is NOT blocked
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

echo "=== INFRA-1604 deep lease path-set collision tests ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.git" "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" \
         "$FAKE_REPO/scripts/coord/lib" "$FAKE_REPO/docs/gaps"

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

cp "$REPO_ROOT/scripts/coord/lib/hot-files.yaml" \
   "$FAKE_REPO/scripts/coord/lib/hot-files.yaml"

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

write_sibling_lease() {
    local session="$1"
    local sibling_gap="$2"
    shift 2
    local paths_json=""
    local sep=""
    for p in "$@"; do
        paths_json="${paths_json}${sep}\"$p\""
        sep=","
    done
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local exp
    exp=$(date -u -v+4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
          date -u -d "+4 hours" +%Y-%m-%dT%H:%M:%SZ)
    cat > "$FAKE_REPO/.chump-locks/${session}.json" <<JSON
{
  "session_id": "$session",
  "gap_id": "$sibling_gap",
  "paths": [$paths_json],
  "taken_at": "$now",
  "expires_at": "$exp",
  "heartbeat_at": "$now",
  "purpose": "gap:$sibling_gap"
}
JSON
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

# 3 sibling leases with distinct declared path-sets (glob + dir-prefix + plain).
write_sibling_lease "sibling-glob-01" "INFRA-SIB01" "src/foo/*.rs"
write_sibling_lease "sibling-dir-02"  "INFRA-SIB02" "docs/"
write_sibling_lease "sibling-plain-03" "INFRA-SIB03" "scripts/coord/unrelated.sh"

# ── Check 1: glob overlap blocked without --force-overlap (exit 16) ──────────
echo "Check 1: 4th claim with glob-overlapping --paths blocked (exit 16)"

seed_gap_db "INFRA-TEST01" "Implement the new claim path helper."
rm -f "$AMBIENT"
rm -rf "$WORK/worktrees/chump-infra-test01"

set +e
CLAIM_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/bar.rs" 2>&1)
CLAIM_RC=$?
set -e

if [[ $CLAIM_RC -eq 16 ]]; then
    ok "claim exited 16 (lease path-set collision block)"
elif [[ $CLAIM_RC -ne 0 ]]; then
    if echo "$CLAIM_OUT" | grep -qi "lease.path.collision\|INFRA-1604"; then
        ok "claim blocked with lease-path-collision message (rc=$CLAIM_RC)"
    else
        fail "claim exited $CLAIM_RC but no lease-path-collision message (output: $CLAIM_OUT)"
    fi
else
    fail "claim should have been blocked but exited 0"
fi

if echo "$CLAIM_OUT" | grep -qi "INFRA-1604\|LEASE PATH COLLISION"; then
    ok "lease path collision warning printed to stderr"
else
    fail "expected lease-path-collision warning in output, got: $CLAIM_OUT"
fi

if echo "$CLAIM_OUT" | grep -qi "force.overlap"; then
    ok "--force-overlap hint printed in error message"
else
    fail "expected --force-overlap hint in output, got: $CLAIM_OUT"
fi

# ── Check 2: ambient event emitted with correct fields ────────────────────────
echo
echo "Check 2: kind=lease_path_collision emitted to ambient.jsonl"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event present in ambient.jsonl"
else
    fail "lease_path_collision event NOT found (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"claim_gap":"INFRA-TEST01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct claim_gap field"
else
    fail "ambient event missing claim_gap field"
fi

if grep -q '"sibling_gap":"INFRA-SIB01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct sibling_gap field"
else
    fail "ambient event missing sibling_gap field"
fi

if grep -q '"overlap_paths"' "$AMBIENT" 2>/dev/null && grep -q '"paths_count"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has overlap_paths + paths_count fields"
else
    fail "ambient event missing overlap_paths/paths_count fields"
fi

# ── Check 3: claim succeeds with --force-overlap ──────────────────────────────
echo
echo "Check 3: claim succeeds with --force-overlap"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
FORCE_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/bar.rs" --force-overlap 2>&1)
FORCE_RC=$?
set -e

if [[ $FORCE_RC -eq 16 ]]; then
    fail "claim exited 16 even with --force-overlap — should have proceeded"
else
    ok "claim did NOT exit 16 with --force-overlap (rc=$FORCE_RC)"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event still emitted with --force-overlap"
else
    fail "lease_path_collision event NOT emitted when --force-overlap used"
fi

# ── Check 4: directory-prefix overlap detected ('docs/' vs 'docs/gaps/X.yaml') ─
echo
echo "Check 4: directory-prefix overlap detected"

seed_gap_db "INFRA-TEST02" "Add a new gap doc."
rm -f "$AMBIENT"
rm -rf "$WORK/worktrees/chump-infra-test02"

set +e
DIR_OUT=$(run_claim "INFRA-TEST02" --paths "docs/gaps/INFRA-9999.yaml" 2>&1)
DIR_RC=$?
set -e

if [[ $DIR_RC -eq 16 ]]; then
    ok "directory-prefix overlap blocked (rc=16)"
else
    fail "directory-prefix overlap NOT blocked (rc=$DIR_RC): $DIR_OUT"
fi

if grep -q '"sibling_gap":"INFRA-SIB02"' "$AMBIENT" 2>/dev/null; then
    ok "directory-prefix collision correctly attributed to sibling-dir-02 (INFRA-SIB02)"
else
    fail "directory-prefix collision not attributed to correct sibling"
fi

# ── Check 5: non-overlapping --paths against all 3 siblings → not blocked ────
echo
echo "Check 5: non-overlapping claim vs 3 siblings is not blocked"

seed_gap_db "INFRA-TEST03" "Touch an unrelated file."
rm -f "$AMBIENT"
rm -rf "$WORK/worktrees/chump-infra-test03"

set +e
CLEAN_OUT=$(run_claim "INFRA-TEST03" --paths "crates/chump-team/src/lib.rs" 2>&1)
CLEAN_RC=$?
set -e

if [[ $CLEAN_RC -eq 16 ]]; then
    fail "claim blocked (rc=16) for non-overlapping path set"
else
    ok "claim not blocked (rc=$CLEAN_RC) for non-overlapping path set"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    fail "spurious lease_path_collision event emitted for non-overlapping paths"
else
    ok "no spurious lease_path_collision event for non-overlapping paths"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
