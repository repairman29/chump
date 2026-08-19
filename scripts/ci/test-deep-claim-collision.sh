#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-deep-claim-collision.sh — INFRA-1604
#
# CI test for the deep claim-collision check in `chump claim`: full path-set
# intersection of THIS claim's --paths against every sibling lease's declared
# paths[], with glob + directory-prefix overlap (not just the 5 hardcoded
# hot files from INFRA-1394).
#
# Verifies:
#   1. 3 sibling leases seeded with glob/dir-prefix/exact paths
#   2. A 4th claim whose --paths overlaps ONE sibling (glob match) is blocked
#      WITHOUT --force-overlap
#   3. The same claim SUCCEEDS with --force-overlap
#   4. kind=lease_path_collision is emitted to ambient.jsonl in both cases,
#      naming the correct sibling_session/sibling_gap
#   5. A claim whose --paths does NOT overlap any sibling is NOT blocked
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

echo "=== INFRA-1604 chump claim deep path-collision tests ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.git" "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" \
         "$FAKE_REPO/scripts/coord/lib"

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

# No hot-files.yaml copied in — this test is exercising the deep path-set
# check, not the INFRA-1394 AC-text scan (that path is covered by
# test-claim-hot-file-overlap.sh).

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

# ── Seed 3 sibling leases with distinct overlap shapes ────────────────────────
echo "[Seed] 3 sibling leases: glob / directory-prefix / exact"
write_sibling_lease "sibling-glob" "INFRA-GLOB01" "src/foo/*.rs"
write_sibling_lease "sibling-dir" "INFRA-DIR01" "docs/"
write_sibling_lease "sibling-exact" "INFRA-EXACT01" "web/v2/other.js"
ok "3 sibling leases written"

# ── Check 1: 4th claim whose --paths glob-overlaps sibling-glob is blocked ────
echo
echo "Check 1: claim blocked without --force-overlap (glob overlap with sibling-glob)"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST01" "Implement the new formatter."
rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
CLAIM_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/bar.rs" 2>&1)
CLAIM_RC=$?
set -e

if [[ $CLAIM_RC -eq 15 ]]; then
    ok "claim exited 15 (lease path collision block) without --force-overlap"
elif [[ $CLAIM_RC -ne 0 ]]; then
    if echo "$CLAIM_OUT" | grep -qi "path collision\|overlap\|force.overlap"; then
        ok "claim blocked with lease-path-collision message (rc=$CLAIM_RC)"
    else
        fail "claim exited $CLAIM_RC but no lease-path-collision message (output: $CLAIM_OUT)"
    fi
else
    fail "claim should have been blocked but exited 0"
fi

if echo "$CLAIM_OUT" | grep -qi "INFRA-1604\|LEASE PATH COLLISION"; then
    ok "lease-path-collision warning message printed to stderr"
else
    fail "expected lease-path-collision warning in output, got: $CLAIM_OUT"
fi

if echo "$CLAIM_OUT" | grep -q "sibling-glob"; then
    ok "colliding sibling session (sibling-glob) named in output"
else
    fail "expected sibling-glob session named in output, got: $CLAIM_OUT"
fi

if echo "$CLAIM_OUT" | grep -qi "force.overlap"; then
    ok "--force-overlap hint printed in error message"
else
    fail "expected --force-overlap hint in output, got: $CLAIM_OUT"
fi

# ── Check 2: ambient event emitted, naming the correct sibling ───────────────
echo
echo "Check 2: kind=lease_path_collision emitted to ambient.jsonl"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event present in ambient.jsonl"
else
    fail "lease_path_collision event NOT found in ambient.jsonl (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"claim_gap":"INFRA-TEST01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct claim_gap field"
else
    fail "ambient event missing correct claim_gap field"
fi

if grep -q '"sibling_gap":"INFRA-GLOB01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event names the correct sibling_gap (INFRA-GLOB01)"
else
    fail "ambient event missing correct sibling_gap"
fi

if grep -q '"sibling_session":"sibling-glob"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event names the correct sibling_session"
else
    fail "ambient event missing correct sibling_session"
fi

if grep -q '"paths_count"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has paths_count field"
else
    fail "ambient event missing paths_count field"
fi

# ── Check 3: claim SUCCEEDS with --force-overlap, event still emitted ─────────
echo
echo "Check 3: claim succeeds with --force-overlap"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
FORCE_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/bar.rs" --force-overlap 2>&1)
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

# ── Check 4: claim whose --paths overlaps NO sibling is not blocked ──────────
echo
echo "Check 4: claim with disjoint --paths is not blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST02" "Implement an unrelated module."
rm -rf "$WORK/worktrees/chump-infra-test02"
rm -f "$AMBIENT"

set +e
DISJOINT_OUT=$(run_claim "INFRA-TEST02" --paths "src/totally/unrelated.rs" 2>&1)
DISJOINT_RC=$?
set -e

if [[ $DISJOINT_RC -eq 15 ]]; then
    fail "claim blocked (rc=15) for disjoint --paths (output: $DISJOINT_OUT)"
else
    ok "claim not blocked (rc=$DISJOINT_RC) for disjoint --paths"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    fail "spurious lease_path_collision event emitted for disjoint --paths"
else
    ok "no spurious lease_path_collision event for disjoint --paths"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
