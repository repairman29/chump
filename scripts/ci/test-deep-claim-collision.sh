#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-deep-claim-collision.sh — INFRA-1604
#
# CI test for the deep claim-collision check in `chump claim`: full
# path-set intersection of the new claim's declared --paths against every
# sibling lease's declared paths[] (glob + directory-prefix aware), as
# opposed to the INFRA-1394 AC-text-vs-hot-file-list heuristic.
#
# Verifies:
#   1. 3 sibling leases with overlapping path globs/dirs are seeded
#   2. A 4th claim whose --paths glob-overlaps sibling A and dir-overlaps
#      sibling B (but NOT sibling C) is BLOCKED without --force-overlap
#   3. kind=lease_path_collision is emitted to ambient.jsonl with the
#      correct claim_gap/sibling_gap/overlap_paths/paths_count fields
#   4. The same claim SUCCEEDS with --force-overlap (event still emitted)
#   5. A claim with --paths that overlaps no sibling is NOT blocked
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

echo "=== INFRA-1604 deep claim-collision (lease paths[] intersection) tests ==="
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

# No hot-files.yaml in the fake repo (or an empty one) — this test is only
# exercising the 5.58 lease-paths[] intersection check, not the 5.6 AC-text
# scan. An absent hot-files.yaml means load_hot_files() returns empty and
# the 5.6 check is a no-op.

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
        --role fleet-test \
        --skip-doctor --skip-import \
        "$@" 2>&1
}

mkdir -p "$WORK/worktrees"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Check 1: seed 3 sibling leases with overlapping path globs/dirs ──────────
echo "Check 1: seed 3 sibling leases (glob, dir-prefix, unrelated)"

seed_gap_db "INFRA-TEST01" "Implement the new reconciliation pass."
write_sibling_lease "sibling-a" "INFRA-SIBA" "src/foo/*.rs"
write_sibling_lease "sibling-b" "INFRA-SIBB" "docs/"
write_sibling_lease "sibling-c" "INFRA-SIBC" "unrelated/path.txt"

if [[ -f "$FAKE_REPO/.chump-locks/sibling-a.json" ]] && \
   [[ -f "$FAKE_REPO/.chump-locks/sibling-b.json" ]] && \
   [[ -f "$FAKE_REPO/.chump-locks/sibling-c.json" ]]; then
    ok "3 sibling lease files seeded"
else
    fail "failed to seed all 3 sibling lease files"
fi

# ── Check 2: 4th claim overlaps sibling-a (glob) + sibling-b (dir), not -c ───
echo
echo "Check 2: claim BLOCKED without --force-overlap (glob + dir overlap)"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
CLAIM_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/bar.rs,docs/gaps/X.yaml" 2>&1)
CLAIM_RC=$?
set -e

if [[ $CLAIM_RC -eq 15 ]]; then
    ok "claim exited 15 (lease path collision block) without --force-overlap"
elif echo "$CLAIM_OUT" | grep -qi "lease path collision\|INFRA-1604"; then
    ok "claim blocked with lease-path-collision message (rc=$CLAIM_RC)"
else
    fail "claim exited $CLAIM_RC with no collision message (output: $CLAIM_OUT)"
fi

if echo "$CLAIM_OUT" | grep -qi "INFRA-1604\|LEASE PATH COLLISION"; then
    ok "INFRA-1604 collision warning printed to stderr"
else
    fail "expected INFRA-1604 collision warning in output, got: $CLAIM_OUT"
fi

if echo "$CLAIM_OUT" | grep -qi "force.overlap"; then
    ok "--force-overlap hint printed in error message"
else
    fail "expected --force-overlap hint in output, got: $CLAIM_OUT"
fi

# ── Check 3: ambient event has correct fields ────────────────────────────────
echo
echo "Check 3: kind=lease_path_collision emitted with correct fields"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event present in ambient.jsonl"
else
    fail "lease_path_collision event NOT found (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"claim_gap":"INFRA-TEST01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct claim_gap field"
else
    fail "ambient event missing/incorrect claim_gap field"
fi

if grep -q '"overlap_paths"' "$AMBIENT" 2>/dev/null && grep -q '"paths_count"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has overlap_paths + paths_count fields"
else
    fail "ambient event missing overlap_paths or paths_count field"
fi

# One line per collision — expect events for BOTH sibling-a and sibling-b,
# but NOT sibling-c (its declared path doesn't overlap either claimed path).
SIBA_HIT=$(grep -c '"sibling_gap":"INFRA-SIBA"' "$AMBIENT" 2>/dev/null || true)
SIBB_HIT=$(grep -c '"sibling_gap":"INFRA-SIBB"' "$AMBIENT" 2>/dev/null || true)
SIBC_HIT=$(grep -c '"sibling_gap":"INFRA-SIBC"' "$AMBIENT" 2>/dev/null || true)

if [[ "${SIBA_HIT:-0}" -ge 1 ]]; then
    ok "collision event emitted for glob-overlapping sibling INFRA-SIBA"
else
    fail "expected a collision event for INFRA-SIBA (glob overlap), found none"
fi

if [[ "${SIBB_HIT:-0}" -ge 1 ]]; then
    ok "collision event emitted for dir-prefix-overlapping sibling INFRA-SIBB"
else
    fail "expected a collision event for INFRA-SIBB (dir-prefix overlap), found none"
fi

if [[ "${SIBC_HIT:-0}" -eq 0 ]]; then
    ok "no collision event emitted for unrelated sibling INFRA-SIBC"
else
    fail "spurious collision event emitted for unrelated sibling INFRA-SIBC"
fi

# ── Check 4: claim SUCCEEDS with --force-overlap ─────────────────────────────
echo
echo "Check 4: claim succeeds with --force-overlap (event still emitted)"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"
# INFRA-1970 gap-claim marker from Check 2's early-exit(15) is still live
# (process::exit skips the marker's Drop-guard cleanup) — clear it so Check 4
# isn't spuriously blocked by "gap already claimed" instead of exercising the
# thing we're actually testing. Pre-existing behavior shared with the
# INFRA-1394 hot-file-overlap test; not specific to this check.
rm -f "$FAKE_REPO"/.chump-locks/gap-claim-*.json

set +e
FORCE_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/bar.rs,docs/gaps/X.yaml" --force-overlap 2>&1)
FORCE_RC=$?
set -e

if [[ $FORCE_RC -eq 15 ]]; then
    fail "claim exited 15 even with --force-overlap — should have proceeded"
else
    ok "claim did NOT exit 15 with --force-overlap (rc=$FORCE_RC)"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event emitted even with --force-overlap"
else
    fail "lease_path_collision event NOT emitted when --force-overlap used"
fi

# ── Check 5: claim with non-overlapping --paths is NOT blocked ──────────────
echo
echo "Check 5: claim with non-overlapping --paths is not blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST02" "Implement an unrelated feature."
rm -rf "$WORK/worktrees/chump-infra-test02"
rm -f "$AMBIENT"

set +e
CLEAN_OUT=$(run_claim "INFRA-TEST02" --paths "crates/chump-planner/src/lib.rs" 2>&1)
CLEAN_RC=$?
set -e

if [[ $CLEAN_RC -eq 15 ]]; then
    fail "claim blocked (rc=15) for --paths with no sibling overlap"
else
    ok "claim not blocked (rc=$CLEAN_RC) when --paths has no sibling overlap"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    fail "spurious lease_path_collision event emitted for non-overlapping --paths"
else
    ok "no spurious lease_path_collision event for non-overlapping --paths"
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
