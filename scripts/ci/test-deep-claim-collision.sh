#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-deep-claim-collision.sh — INFRA-1604
#
# CI test for the deep lease path-set collision check in `chump claim`
# (structural successor to INFRA-1394's AC-text hot-file scan — this one
# intersects the actual declared paths[] of every sibling lease, with glob
# + directory-prefix matching).
#
# Verifies:
#   1. Synthesize 3 sibling leases with overlapping path globs/dirs
#   2. A 4th claim whose paths[] intersects those siblings is BLOCKED
#      without --force-overlap (exit 16), reporting all colliding siblings
#   3. The same claim SUCCEEDS with --force-overlap
#   4. kind=lease_path_collision is emitted to ambient.jsonl in both cases,
#      with claim_gap/sibling_gap/sibling_session/overlap_paths/paths_count
#   5. A claim with disjoint paths[] is NOT blocked
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

echo "=== INFRA-1604 chump claim deep lease path-collision tests ==="
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

# No hot-files.yaml copied in — this test exercises the INFRA-1604 lease
# path-set check specifically, independent of the INFRA-1394 AC-text check.

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

# ── Setup: 3 sibling leases with overlapping path globs/dirs ─────────────────
echo "Setup: 3 sibling leases with glob + directory-prefix path declarations"
write_sibling_lease "sibling-A" "INFRA-SIB-A" "src/foo/bar.rs"
write_sibling_lease "sibling-B" "INFRA-SIB-B" "docs/gaps/other.yaml"
write_sibling_lease "sibling-C" "INFRA-SIB-C" "src/unrelated/thing.rs"
ok "3 sibling leases written (sibling-A: src/foo/bar.rs, sibling-B: docs/gaps/other.yaml, sibling-C: src/unrelated/thing.rs)"

# ── Check 1: 4th claim with glob + dir-prefix paths → BLOCKED (exit 16) ──────
echo
echo "Check 1: 4th claim (paths: src/foo/*.rs, docs/) blocked without --force-overlap"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST01" "Refactor the foo module and update gap docs."
rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
CLAIM_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/*.rs,docs/" 2>&1)
CLAIM_RC=$?
set -e

if [[ $CLAIM_RC -eq 16 ]]; then
    ok "claim exited 16 (lease path collision block) without --force-overlap"
elif [[ $CLAIM_RC -ne 0 ]]; then
    if echo "$CLAIM_OUT" | grep -qi "lease.path.collision\|INFRA-1604"; then
        ok "claim blocked with lease-path-collision message (rc=$CLAIM_RC)"
    else
        fail "claim exited $CLAIM_RC but no lease-path-collision message (output: $CLAIM_OUT)"
    fi
else
    fail "claim should have been blocked but exited 0"
fi

if echo "$CLAIM_OUT" | grep -qi "INFRA-1604"; then
    ok "INFRA-1604 collision message printed to stderr"
else
    fail "expected INFRA-1604 message in output, got: $CLAIM_OUT"
fi

# Glob match: src/foo/*.rs should catch sibling-A's src/foo/bar.rs.
if echo "$CLAIM_OUT" | grep -qi "sibling-A"; then
    ok "glob overlap detected against sibling-A (src/foo/*.rs ~ src/foo/bar.rs)"
else
    fail "expected glob overlap against sibling-A, got: $CLAIM_OUT"
fi

# Directory-prefix match: docs/ should catch sibling-B's docs/gaps/other.yaml.
if echo "$CLAIM_OUT" | grep -qi "sibling-B"; then
    ok "directory-prefix overlap detected against sibling-B (docs/ ~ docs/gaps/other.yaml)"
else
    fail "expected directory-prefix overlap against sibling-B, got: $CLAIM_OUT"
fi

# sibling-C (src/unrelated/thing.rs) should NOT collide with our paths.
if echo "$CLAIM_OUT" | grep -qi "sibling-C"; then
    fail "spurious overlap reported against sibling-C (disjoint path), got: $CLAIM_OUT"
else
    ok "no spurious overlap against sibling-C (disjoint path)"
fi

if echo "$CLAIM_OUT" | grep -qi "force.overlap"; then
    ok "--force-overlap hint printed in error message"
else
    fail "expected --force-overlap hint in output, got: $CLAIM_OUT"
fi

# ── Check 2: ambient event emitted per colliding sibling ─────────────────────
echo
echo "Check 2: kind=lease_path_collision emitted to ambient.jsonl (one per sibling)"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event present in ambient.jsonl"
else
    fail "lease_path_collision event NOT found in ambient.jsonl (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

EVENT_COUNT=$(grep -c '"kind":"lease_path_collision"' "$AMBIENT" 2>/dev/null || echo 0)
if [[ "$EVENT_COUNT" -ge 2 ]]; then
    ok "at least 2 lease_path_collision events emitted (one per colliding sibling): $EVENT_COUNT"
else
    fail "expected >=2 lease_path_collision events, got $EVENT_COUNT"
fi

if grep -q '"claim_gap":"INFRA-TEST01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct claim_gap field"
else
    fail "ambient event missing claim_gap field"
fi

if grep -q '"overlap_paths"' "$AMBIENT" 2>/dev/null && grep -q '"paths_count"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has overlap_paths + paths_count fields"
else
    fail "ambient event missing overlap_paths/paths_count field"
fi

if grep -q '"sibling_session":"sibling-A"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event records sibling_session=sibling-A"
else
    fail "ambient event missing sibling_session=sibling-A"
fi

# ── Check 3: claim SUCCEEDS with --force-overlap ──────────────────────────────
echo
echo "Check 3: claim succeeds with --force-overlap"

rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
FORCE_OUT=$(run_claim "INFRA-TEST01" --paths "src/foo/*.rs,docs/" --force-overlap 2>&1)
FORCE_RC=$?
set -e

if [[ $FORCE_RC -eq 16 ]]; then
    fail "claim exited 16 even with --force-overlap — should have proceeded"
else
    ok "claim did NOT exit 16 with --force-overlap (rc=$FORCE_RC)"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    ok "lease_path_collision event still emitted even with --force-overlap"
else
    fail "lease_path_collision event NOT emitted when --force-overlap used"
fi

# ── Check 4: disjoint paths[] → not blocked ────────────────────────────────────
echo
echo "Check 4: claim with disjoint paths[] is not blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST02" "Implement the reconciliation loop."
rm -rf "$WORK/worktrees/chump-infra-test02"
rm -f "$AMBIENT"

set +e
DISJOINT_OUT=$(run_claim "INFRA-TEST02" --paths "src/reconcile.rs" 2>&1)
DISJOINT_RC=$?
set -e

if [[ $DISJOINT_RC -eq 16 ]]; then
    fail "claim blocked (rc=16) for disjoint paths[]: $DISJOINT_OUT"
else
    ok "claim not blocked (rc=$DISJOINT_RC) for disjoint paths[]"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"lease_path_collision"' "$AMBIENT"; then
    fail "spurious lease_path_collision event emitted for disjoint paths[]"
else
    ok "no spurious lease_path_collision event for disjoint paths[]"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
