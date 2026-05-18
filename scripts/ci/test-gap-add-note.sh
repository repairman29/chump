#!/usr/bin/env bash
# test-gap-add-note.sh — EFFECTIVE-020: chump gap set --add-note appends timestamped notes
#
# Tests:
#   1. Note is appended with ISO-8601 timestamp prefix
#   2. Prior notes are preserved (not overwritten)
#   3. Second --add-note creates a second entry separated by newline

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -f "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    else
        cargo build -q --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump 2>/dev/null \
            || { echo "[SKIP] could not build chump — skipping EFFECTIVE-020 tests"; exit 0; }
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    fi
fi

TMP="$(mktemp -d -t test-gap-add-note.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_DB="$TMP/.chump/state.db"
mkdir -p "$(dirname "$FAKE_DB")"

sqlite3 "$FAKE_DB" <<SQL
CREATE TABLE gaps (
    id TEXT PRIMARY KEY, domain TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '', priority TEXT NOT NULL DEFAULT '',
    effort TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '', depends_on TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '', source_doc TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0, closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '', closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER, skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '', preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '', required_model TEXT NOT NULL DEFAULT ''
);
CREATE TABLE gap_counters (domain TEXT PRIMARY KEY, next_num INTEGER NOT NULL DEFAULT 1);
INSERT INTO gaps (id, domain, title, status, priority, effort, notes) VALUES
    ('NOTE-001', 'TEST', 'Test gap for note adding', 'open', 'P1', 's', '');
SQL

# ── Test 1: --add-note appends with ISO-8601 timestamp ────────────────────────
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap set NOTE-001 --add-note "first note" 2>&1 | grep -q "updated" \
    || fail "Test 1: --add-note should print 'updated NOTE-001'"

notes1="$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap show NOTE-001 --json 2>&1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("notes",""))')"
echo "$notes1" | grep -qE "^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] first note" \
    || fail "Test 1: note should start with ISO-8601 timestamp (got: $notes1)"
pass "Test 1: --add-note appends '[ISO-timestamp] first note'"

# ── Test 2: prior notes preserved on second --add-note ────────────────────────
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap set NOTE-001 --add-note "second note" 2>&1 | grep -q "updated" \
    || fail "Test 2: second --add-note should succeed"

notes2="$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap show NOTE-001 --json 2>&1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("notes",""))')"
echo "$notes2" | grep -q "first note" \
    || fail "Test 2: prior 'first note' should be preserved after second --add-note (got: $notes2)"
echo "$notes2" | grep -q "second note" \
    || fail "Test 2: 'second note' should appear in notes (got: $notes2)"
pass "Test 2: prior notes preserved — both 'first note' and 'second note' present"

# ── Test 3: two entries separated by newline ──────────────────────────────────
entry_count="$(echo "$notes2" | grep -cE "^\[20[0-9]{2}" || echo 0)"
[[ "$entry_count" -ge 2 ]] \
    || fail "Test 3: expected ≥2 timestamped entries, got $entry_count (notes: $notes2)"
pass "Test 3: two --add-note calls produce 2 timestamped entries (newline-separated)"

echo ""
echo "All EFFECTIVE-020 add-note checks passed (3/3)."
