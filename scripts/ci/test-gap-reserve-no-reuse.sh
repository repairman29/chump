#!/usr/bin/env bash
# test-gap-reserve-no-reuse.sh — INFRA-1954
#
# Reproduces the 2026-05-25 Cold Water incident: `chump gap reserve`
# re-issued IDs (META-103, INFRA-1953, INFRA-1955, INFRA-1957) that had
# already shipped and whose docs/gaps/<ID>.yaml had been *deleted* rather
# than archived to docs/gaps/closed/. The state.db gap_counters row only
# knows about rows currently in state.db, so once a domain's counter drifts
# out of sync with git history, reserve can hand the same ID out twice.
#
# This test simulates that drift directly (rewind gap_counters.next_num for
# a domain to a number already referenced in a shipped commit) and asserts
# `chump gap reserve` refuses to reuse it — the INFRA-1954 git-history guard.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-1954 gap-reserve no-ID-reuse test ==="
echo

if grep -q 'fn id_in_git_history' "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "id_in_git_history guard present in chump-gap-store"
else
    fail "id_in_git_history guard not found in chump-gap-store/src/lib.rs"
fi

if grep -q 'gap_id_reuse_blocked' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "gap_id_reuse_blocked registered in EVENT_REGISTRY.yaml"
else
    fail "gap_id_reuse_blocked missing from EVENT_REGISTRY.yaml"
fi

# ── Functional test ─────────────────────────────────────────────────────────

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    RUSTC_WRAPPER="" cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional test"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "  [skip] sqlite3 not installed — skipping functional test"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_RESERVE_SCAN_OPEN_PRS=0
export CHUMP_RESERVE_VERIFY_SLEEP_MS=0

git -C "$TMP" init -q
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name "Test"
git -C "$TMP" commit -q --allow-empty -m "chore: seed"

# 1. Reserve a gap — first INFRA reservation in this isolated repo, so it
#    lands on INFRA-001.
ID1=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "dummy gap for no-reuse test" \
    --skip-obs-acs --quiet 2>/dev/null || true)
if [[ "$ID1" == "INFRA-001" ]]; then
    ok "(1) dummy gap reserved as INFRA-001"
else
    fail "(1) expected INFRA-001, got '$ID1'"
fi

# 2. Simulate the ship: a commit referencing the ID lands, then its
#    state.db row + YAML mirror are removed (docs/gaps/closed/ never used).
git -C "$TMP" commit -q --allow-empty \
    -m "feat($ID1): dummy gap shipped (docs/gaps/$ID1.yaml deleted, not archived)"
sqlite3 "$TMP/.chump/state.db" "DELETE FROM gaps WHERE id='$ID1';"

# 3. Simulate gap_counters drift: rewind the domain counter back to the
#    reused ID's number, reproducing the Cold Water pattern where the
#    counter no longer reflects the shipped ID.
sqlite3 "$TMP/.chump/state.db" "UPDATE gap_counters SET next_num = 1 WHERE domain='INFRA';"

# 4. Reserve again — must NOT hand back INFRA-001 (rejected), or if the
#    binary retries transparently, must NOT be INFRA-001 either way.
OUT2=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "attempted reuse of INFRA-001" \
    --skip-obs-acs --quiet 2>&1 || true)
if echo "$OUT2" | grep -q "INFRA-001"; then
    fail "(4) reserve reused INFRA-001 after it shipped and was removed (output: $OUT2)"
else
    ok "(4) reserve did not hand back the reused ID INFRA-001"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
