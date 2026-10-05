#!/usr/bin/env bash
# scripts/ci/test-github-cache-divergence-audit.sh — INFRA-3833
#
# Smoke test for scripts/ops/github-cache-divergence-audit.sh:
#   1. Missing DB / missing pr_state_write_log table → clean no-op (rc=0,
#      no ambient event).
#   2. Two sources agreeing on a PR's state → no divergence emitted.
#   3. Two sources disagreeing on mergeable_state → kind=cache_divergence_detected
#      emitted with the correct pr_number + both sides' values.
#   4. A log row outside the lookback window is ignored (stale writes
#      from a receiver that's been down for days shouldn't re-trigger
#      every night).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT="$REPO_ROOT/scripts/ops/github-cache-divergence-audit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '      %s\n' "$*"; }

if [[ ! -x "$AUDIT" ]]; then
    fail "audit script not found or not executable: $AUDIT"
    echo "PASS: $PASS  FAIL: $FAIL"
    exit 1
fi

seed_log_table() {
    local db="$1"
    sqlite3 "$db" <<'SQL'
CREATE TABLE pr_state_write_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    number INTEGER NOT NULL,
    source TEXT NOT NULL,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    title TEXT,
    written_at TEXT NOT NULL
);
SQL
}

insert_row() {
    local db="$1" number="$2" source="$3" state="$4" am="$5" draft="$6" title="$7" ts="$8"
    sqlite3 "$db" "INSERT INTO pr_state_write_log(number, source, mergeable_state, auto_merge_enabled, draft, title, written_at) VALUES ($number, '$source', '$state', $am, $draft, '$title', '$ts');"
}

# ---------------------------------------------------------------------------
# Test 1: missing DB → clean no-op.
# ---------------------------------------------------------------------------
DB1="$TMP/missing.db"
AMB1="$TMP/ambient1.jsonl"
if CHUMP_CACHE_DB="$DB1" CHUMP_AMBIENT_LOG="$AMB1" "$AUDIT" >/dev/null 2>&1; then
    if [[ ! -f "$AMB1" ]]; then
        ok "missing DB: clean no-op, no ambient file created"
    else
        fail "missing DB: ambient file unexpectedly created"
    fi
else
    fail "missing DB: audit script exited nonzero"
fi

# ---------------------------------------------------------------------------
# Test 2: agreeing sources → no divergence.
# ---------------------------------------------------------------------------
DB2="$TMP/agree.db"
AMB2="$TMP/ambient2.jsonl"
seed_log_table "$DB2"
insert_row "$DB2" 100 python clean 1 0 "feat: thing" "2026-10-01T10:00:00Z"
insert_row "$DB2" 100 rust   clean 1 0 "feat: thing" "2026-10-01T10:00:05Z"
CHUMP_CACHE_DB="$DB2" CHUMP_AMBIENT_LOG="$AMB2" "$AUDIT" >/dev/null 2>&1
if [[ ! -s "$AMB2" ]]; then
    ok "agreeing sources: no cache_divergence_detected emitted"
else
    fail "agreeing sources: unexpected ambient output"
    note "got: $(cat "$AMB2")"
fi

# ---------------------------------------------------------------------------
# Test 3: disagreeing sources → divergence emitted with correct fields.
# ---------------------------------------------------------------------------
DB3="$TMP/diverge.db"
AMB3="$TMP/ambient3.jsonl"
seed_log_table "$DB3"
insert_row "$DB3" 200 python clean 1 0 "feat: thing" "2026-10-01T10:00:00Z"
insert_row "$DB3" 200 rust   dirty 1 0 "feat: thing" "2026-10-01T10:00:05Z"
CHUMP_CACHE_DB="$DB3" CHUMP_AMBIENT_LOG="$AMB3" "$AUDIT" >/dev/null 2>&1
if grep -q '"kind":"cache_divergence_detected"' "$AMB3" 2>/dev/null; then
    ok "disagreeing sources: cache_divergence_detected emitted"
    if grep -q '"pr_number":200' "$AMB3" && grep -q '"mergeable_state":"clean"' "$AMB3" && grep -q '"mergeable_state":"dirty"' "$AMB3"; then
        ok "divergence event carries pr_number + both sides' mergeable_state"
    else
        fail "divergence event missing expected fields"
        note "got: $(cat "$AMB3")"
    fi
else
    fail "disagreeing sources: no cache_divergence_detected emitted"
    note "ambient contents: $(cat "$AMB3" 2>/dev/null || echo '(empty)')"
fi

# ---------------------------------------------------------------------------
# Test 4: stale rows outside the lookback window are ignored.
# ---------------------------------------------------------------------------
DB4="$TMP/stale.db"
AMB4="$TMP/ambient4.jsonl"
seed_log_table "$DB4"
insert_row "$DB4" 300 python clean 1 0 "feat: old" "2020-01-01T00:00:00Z"
insert_row "$DB4" 300 rust   dirty 1 0 "feat: old" "2020-01-01T00:00:05Z"
CHUMP_CACHE_DB="$DB4" CHUMP_AMBIENT_LOG="$AMB4" CHUMP_DIVERGENCE_WINDOW_HOURS=24 "$AUDIT" >/dev/null 2>&1
if [[ ! -s "$AMB4" ]]; then
    ok "stale rows (outside window): correctly ignored"
else
    fail "stale rows (outside window): unexpectedly flagged"
    note "got: $(cat "$AMB4")"
fi

echo
echo "=== test-github-cache-divergence-audit.sh ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
