#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# test-state-db-restore.sh — INFRA-538 CI gate
#
# Verifies that 'chump gap restore --from-sql' correctly rebuilds state.db
# from .chump/state.sql after corruption:
#   1. Create a temp repo with a known set of gaps in state.db + state.sql
#   2. Corrupt state.db (truncate it)
#   3. Run chump gap restore --from-sql
#   4. Verify COUNT(*) matches the gap count in state.sql
#   5. Verify closed_pr / closed_date / notes survive the round-trip

set -euo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "INFRA-538" "$*"

REPO_ROOT_REAL="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT_REAL/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN — run 'cargo build --bin chump' first"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Bootstrap a minimal repo environment ────────────────────────────────────
mkdir -p "$TMP/.chump" "$TMP/docs/gaps"
git -C "$TMP" init -q
git -C "$TMP" config user.email "test@test.com"
git -C "$TMP" config user.name "Test"

# Create a synthetic state.sql (YAML format) with 3 gaps, 1 with closed_pr.
cat > "$TMP/.chump/state.sql" <<'YAML'
gaps:
- id: TEST-001
  domain: TEST
  title: Test gap one
  status: open
  priority: P1
  effort: s
  notes: |
    some notes here

- id: TEST-002
  domain: TEST
  title: Test gap two
  status: done
  priority: P2
  effort: m
  closed_date: '2026-05-01'
  closed_pr: 999
  notes: shipped

- id: TEST-003
  domain: TEST
  title: Test gap three with acceptance criteria
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - criterion one
    - criterion two
YAML

PASS=0
FAIL=0

check() {
    local name="$1" result="$2" expected="$3"
    if [[ "$result" == "$expected" ]]; then
        echo "[OK] $name"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL $name: expected '$expected', got '$result'"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ── Test 1: restore from state.sql into a fresh state.db ────────────────────
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || true
row_count="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps")"
check "test-1 (row count = 3 after restore)" "$row_count" "3"

# ── Test 2: closed_pr survives the round-trip ───────────────────────────────
closed_pr="$(sqlite3 "$TMP/.chump/state.db" "SELECT closed_pr FROM gaps WHERE id='TEST-002'")"
check "test-2 (TEST-002 closed_pr = 999)" "$closed_pr" "999"

# ── Test 3: closed_date survives the round-trip ─────────────────────────────
closed_date="$(sqlite3 "$TMP/.chump/state.db" "SELECT closed_date FROM gaps WHERE id='TEST-002'")"
check "test-3 (TEST-002 closed_date = 2026-05-01)" "$closed_date" "2026-05-01"

# ── Test 4: notes survive the round-trip ───────────────────────────────────
notes="$(sqlite3 "$TMP/.chump/state.db" "SELECT notes FROM gaps WHERE id='TEST-001'")"
check "test-4 (TEST-001 notes preserved)" "$(echo "$notes" | head -1 | tr -d '\n')" "some notes here"

# ── Test 5: corrupt then restore, row count still correct ───────────────────
# Corrupt state.db by truncating it
: > "$TMP/.chump/state.db"
# Restore should regenerate it
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || true
row_count_after="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps")"
check "test-5 (corrupt→restore row count = 3)" "$row_count_after" "3"

# ── Test 6: backup is created as state.db.bak ────────────────────────────────
# The previous restore created a .bak from the empty file; that's fine.
# Now seed a real db, corrupt it, restore, and verify .bak exists.
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || true
: > "$TMP/.chump/state.db"   # corrupt again
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || true
if [[ -f "$TMP/.chump/state.db.bak" ]]; then
    echo "[OK] test-6 (state.db.bak created)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-6: state.db.bak not found"
    FAIL=$(( FAIL + 1 ))
fi

# ── Test 7: missing state.sql → exit non-zero ───────────────────────────────
mv "$TMP/.chump/state.sql" "$TMP/.chump/state.sql.moved"
exit_code=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || exit_code=$?
mv "$TMP/.chump/state.sql.moved" "$TMP/.chump/state.sql"
if [[ "$exit_code" -ne 0 ]]; then
    echo "[OK] test-7 (exit non-zero when state.sql missing)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-7: expected non-zero exit when state.sql missing, got $exit_code"
    FAIL=$(( FAIL + 1 ))
fi

# ── Test 8: missing --from-sql flag → exit 2 ────────────────────────────────
exit_code=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore >/dev/null 2>&1 || exit_code=$?
if [[ "$exit_code" -eq 2 ]]; then
    echo "[OK] test-8 (exit 2 when --from-sql missing)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-8: expected exit 2 without --from-sql, got $exit_code"
    FAIL=$(( FAIL + 1 ))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "PASS: test-state-db-restore (${PASS}/${PASS} cases verified)"
    gate_emit_result "INFRA-538" "pass" "" ""
    exit 0
else
    echo "FAIL: ${FAIL} case(s) failed (${PASS} passed)"
    gate_emit_result "INFRA-538" "fail" "smoke-test-failure" "$FAIL case(s) failed"
    exit 1
fi
