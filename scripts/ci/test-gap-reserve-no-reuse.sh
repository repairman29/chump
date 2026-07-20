#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-no-reuse.sh — INFRA-1954 (2026-07-19)
#
# Regression test for INFRA-1954: chump gap reserve re-used shipped gap
# IDs (META-103, INFRA-1953, INFRA-1955, INFRA-1957) whose rows had drifted
# out of the live registry (state.db row deleted / counter reset) even
# though the ID was permanently burned into a shipped commit message.
#
# The INFRA-018 duplicate-ID guard only checks the *live* registry
# (state.db + docs/gaps/*.yaml) — it is blind to git history. This test
# simulates the exact drift: reserve an ID, "ship" it (commit referencing
# the ID), then force the live registry to forget it (delete the row +
# reset the counter) and assert that a subsequent reserve attempt is
# rejected rather than silently reusing the ID.
#
# Steps:
#  1. Reserve TEST-NNN in an isolated tmp git repo.
#  2. Commit referencing TEST-NNN (simulates "shipped").
#  3. Delete the gaps row + reset gap_counters (simulates registry drift).
#  4. Reserve again — must fail with DUPLICATE, not hand back TEST-NNN.
#  5. Sanity: CHUMP_GAP_RESERVE_SKIP_GIT_HISTORY_CHECK=1 bypasses the guard.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

CHUMP_BIN="${ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
fi
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found; run 'cargo build -p chump' first" >&2
    exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "SKIP: sqlite3 not found" >&2
    exit 0
fi

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TMPREPO="$TMP/repo"
mkdir -p "$TMPREPO"
git -C "$TMPREPO" init -q -b main
git -C "$TMPREPO" config user.email "test@example.com"
git -C "$TMPREPO" config user.name "INFRA-1954 test"
git -C "$TMPREPO" commit -q --allow-empty -m "initial commit"

export CHUMP_REPO="$TMPREPO"
export CHUMP_HOME="$TMPREPO"
export CHUMP_LOCK_DIR="$TMPREPO/.chump-locks"
export CHUMP_GAP_RESERVE_SKIP_PR=1
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_RESERVE_VERIFY=0
mkdir -p "$CHUMP_LOCK_DIR"

echo "=== Step 1: reserve TEST-NNN in isolated repo ==="
ID1=$("$CHUMP_BIN" gap reserve --domain TEST --title "no-reuse fixture gap" \
    --priority P3 --effort xs --skip-obs-acs --quiet 2>"$TMP/stderr1.txt" || true)
if [[ -z "$ID1" ]]; then
    fail "initial reserve returned empty output"
    cat "$TMP/stderr1.txt" >&2
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "reserved $ID1"

echo "=== Step 2: 'ship' — commit referencing $ID1 ==="
git -C "$TMPREPO" commit -q --allow-empty -m "feat($ID1): fixture ship for no-reuse test"
ok "committed feat($ID1) message"

echo "=== Step 3: simulate registry drift (delete row + reset counter) ==="
DB_PATH="$TMPREPO/.chump/state.db"
if [[ ! -f "$DB_PATH" ]]; then
    # Fall back: some layouts key state.db off CHUMP_HOME directly.
    DB_PATH="$(find "$TMPREPO" -name state.db 2>/dev/null | head -1)"
fi
if [[ -z "$DB_PATH" || ! -f "$DB_PATH" ]]; then
    fail "could not locate state.db under $TMPREPO"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
sqlite3 "$DB_PATH" "DELETE FROM gaps WHERE id='$ID1';"
sqlite3 "$DB_PATH" "UPDATE gap_counters SET next_num = (SELECT CAST(SUBSTR('$ID1', LENGTH(domain)+2) AS INTEGER)) WHERE domain='TEST';"
ok "row deleted + counter reset to reproduce $ID1 on next reserve"

echo "=== Step 4: reserve again — must be rejected (DUPLICATE), not reuse $ID1 ==="
ID2=$("$CHUMP_BIN" gap reserve --domain TEST --title "no-reuse fixture gap take 2" \
    --priority P3 --effort xs --skip-obs-acs --quiet 2>"$TMP/stderr2.txt")
RC=$?
if [[ $RC -ne 0 ]]; then
    if grep -qi "DUPLICATE" "$TMP/stderr2.txt"; then
        ok "reserve rejected the drifted ID with DUPLICATE ($ID1 stayed burned)"
    else
        fail "reserve failed but not with a DUPLICATE message"
        cat "$TMP/stderr2.txt" >&2
    fi
elif [[ "$ID2" == "$ID1" ]]; then
    fail "reserve silently re-used $ID1 — INFRA-1954 regression"
else
    fail "reserve succeeded with unexpected id '$ID2' instead of rejecting"
fi

echo "=== Step 5: CHUMP_GAP_RESERVE_SKIP_GIT_HISTORY_CHECK=1 bypasses the guard ==="
ID3=$(CHUMP_GAP_RESERVE_SKIP_GIT_HISTORY_CHECK=1 "$CHUMP_BIN" gap reserve --domain TEST \
    --title "no-reuse fixture gap take 3 (bypass)" \
    --priority P3 --effort xs --skip-obs-acs --quiet 2>"$TMP/stderr3.txt" || true)
if [[ -n "$ID3" ]]; then
    ok "bypass env var allows reserve to proceed ($ID3)"
else
    fail "bypass env var did not allow reserve"
    cat "$TMP/stderr3.txt" >&2
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
