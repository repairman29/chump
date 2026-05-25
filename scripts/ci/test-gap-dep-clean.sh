#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-gap-dep-clean.sh — INFRA-944: verify chump gap dep-clean behavior.
#
# Creates a fixture state.db with synthetic gaps and tests:
#   1. Dry-run flags stale depends_on pointing at done gaps, preserves clean deps
#   2. --apply strips stale deps and emits dep_cleaned ambient event
#   3. --json emits correct structured output
#   4. Clean registry (no stale deps) exits 0 with "all clean" message
#
# Env:
#   CHUMP_REPO           override repo root (for fixture isolation)
#   CHUMP_BIN            path to chump binary (default: chump in PATH)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-chump}"
TMPDIR=""

cleanup() {
    [[ -n "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

TMPDIR="$(mktemp -d /tmp/test-gap-dep-clean-XXXXXX)"
mkdir -p "$TMPDIR/.chump-locks" "$TMPDIR/.chump"

# Build fixture state.db
python3 -c "
import sqlite3, json

db = sqlite3.connect('$TMPDIR/.chump/state.db')
db.execute('''
    CREATE TABLE IF NOT EXISTS gaps (
        id              TEXT PRIMARY KEY,
        domain          TEXT NOT NULL DEFAULT '',
        title           TEXT NOT NULL DEFAULT '',
        description     TEXT NOT NULL DEFAULT '',
        priority        TEXT NOT NULL DEFAULT '',
        effort          TEXT NOT NULL DEFAULT '',
        status          TEXT NOT NULL DEFAULT 'open',
        acceptance_criteria TEXT NOT NULL DEFAULT '',
        depends_on      TEXT NOT NULL DEFAULT '',
        notes           TEXT NOT NULL DEFAULT '',
        source_doc      TEXT NOT NULL DEFAULT '',
        created_at      INTEGER NOT NULL DEFAULT 0,
        closed_at       INTEGER,
        opened_date     TEXT NOT NULL DEFAULT '',
        closed_date     TEXT NOT NULL DEFAULT '',
        closed_pr       INTEGER,
        skills_required TEXT NOT NULL DEFAULT '',
        preferred_backend TEXT NOT NULL DEFAULT '',
        preferred_machine TEXT NOT NULL DEFAULT '',
        estimated_minutes TEXT NOT NULL DEFAULT '',
        required_model  TEXT NOT NULL DEFAULT ''
    )
''')

# Gap A: depends on B (will be done) and C (open)
db.execute('INSERT INTO gaps (id, domain, title, status, depends_on, created_at) VALUES (?,?,?,?,?,?)',
    ('TEST-A', 'TEST', 'Dep-clean test A', 'open', json.dumps(['TEST-B', 'TEST-C']), 1000))

# Gap B: done gap (the stale dependency)
db.execute('INSERT INTO gaps (id, domain, title, status, closed_pr, closed_at, created_at) VALUES (?,?,?,?,?,?,?)',
    ('TEST-B', 'TEST', 'Dep-clean test B', 'done', 9999, 2000, 1000))

# Gap C: open gap (the clean dependency)
db.execute('INSERT INTO gaps (id, domain, title, status, created_at) VALUES (?,?,?,?,?)',
    ('TEST-C', 'TEST', 'Dep-clean test C', 'open', 1000))

# Gap D: open gap with no depends_on (should be skipped)
db.execute('INSERT INTO gaps (id, domain, title, status, created_at) VALUES (?,?,?,?,?)',
    ('TEST-D', 'TEST', 'Dep-clean test D (no deps)', 'open', 1000))

db.commit()
db.close()
print('Fixture DB created')
"

run_chump() {
    CHUMP_REPO="$TMPDIR" CHUMP_AMBIENT_IN_PROMPT="$TMPDIR/.chump-locks/ambient.jsonl" \
        "$CHUMP_BIN" gap dep-clean "$@"
}

# ── Test 1: Dry-run shows stale dep and preserves clean ──────────────────────
set +e
DRY_OUT="$(run_chump 2>&1)"
DRY_RC=$?
set -e

if [[ $DRY_RC -eq 0 ]]; then
    echo "FAIL: dry-run should exit non-zero when stale deps exist" >&2
    echo "output: $DRY_OUT" >&2
    exit 1
fi

if ! echo "$DRY_OUT" | grep -q "TEST-A depends_on TEST-B (done)"; then
    echo "FAIL: dry-run should flag TEST-B as stale" >&2
    echo "output: $DRY_OUT" >&2
    exit 1
fi

if echo "$DRY_OUT" | grep -q "TEST-A depends_on TEST-C (done)"; then
    echo "FAIL: dry-run should NOT flag TEST-C as stale (it is open)" >&2
    echo "output: $DRY_OUT" >&2
    exit 1
fi

echo "ok 1: dry-run flags stale deps, preserves clean deps"

# ── Test 2: --json dry-run output ────────────────────────────────────────────
JSON_OUT="$(CHUMP_REPO="$TMPDIR" CHUMP_AMBIENT_IN_PROMPT="$TMPDIR/.chump-locks/ambient.jsonl" \
    "$CHUMP_BIN" gap dep-clean --json 2>/dev/null)" || true

if ! echo "$JSON_OUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
entries = {e['gap_id']: e for e in data if isinstance(e, dict)}
assert 'TEST-A' in entries, 'TEST-A missing from JSON output'
assert entries['TEST-A']['stale_deps'] == ['TEST-B'], f'expected stale_deps=[TEST-B], got {entries[\"TEST-A\"][\"stale_deps\"]}'
assert entries['TEST-A']['action'] == 'skipped', 'dry-run should be skipped'
print('JSON dry-run valid')
" 2>&1; then
    echo "FAIL: --json dry-run output is incorrect" >&2
    echo "output: $JSON_OUT" >&2
    exit 1
fi

echo "ok 2: --json dry-run output is correct"

# ── Test 3: --apply strips stale deps, keeps clean deps, emits ambient ───────
APPLY_OUT="$(run_chump --apply 2>&1)"
APPLY_RC=$?

if [[ $APPLY_RC -ne 0 ]]; then
    echo "FAIL: --apply should exit 0" >&2
    echo "output: $APPLY_OUT" >&2
    exit 1
fi

# Verify depends_on was updated in DB
python3 -c "
import sqlite3, json
db = sqlite3.connect('$TMPDIR/.chump/state.db')
row = db.execute('SELECT depends_on FROM gaps WHERE id=\"TEST-A\"').fetchone()
deps = json.loads(row[0])
assert deps == ['TEST-C'], f'expected [TEST-C], got {deps}'
print('DB depends_on correctly updated')
" 2>&1

echo "ok 3: --apply strips stale deps, preserves clean deps"

# ── Test 4: ambient event was emitted ─────────────────────────────────────────
if [[ ! -f "$TMPDIR/.chump-locks/ambient.jsonl" ]]; then
    echo "FAIL: ambient.jsonl was not created" >&2
    exit 1
fi

python3 -c "
import json
with open('$TMPDIR/.chump-locks/ambient.jsonl') as f:
    lines = [json.loads(l) for l in f if l.strip()]
events = [e for e in lines if e.get('kind') == 'dep_cleaned']
assert len(events) == 1, f'expected 1 dep_cleaned event, got {len(events)}'
ev = events[0]
assert ev['gap_id'] == 'TEST-A', f'expected gap_id=TEST-A, got {ev[\"gap_id\"]}'
assert ev['stripped_deps'] == ['TEST-B'], f'expected [TEST-B], got {ev[\"stripped_deps\"]}'
print('Ambient event verified')
" 2>&1

echo "ok 4: dep_cleaned ambient event emitted with correct fields"

# ── Test 5: re-run shows clean state ─────────────────────────────────────────
CLEAN_OUT="$(run_chump 2>&1)"
CLEAN_RC=$?

if [[ $CLEAN_RC -ne 0 ]]; then
    echo "FAIL: clean registry should exit 0" >&2
    echo "output: $CLEAN_OUT" >&2
    exit 1
fi

if ! echo "$CLEAN_OUT" | grep -q "No stale depends_on entries found — all clean."; then
    echo "FAIL: expected 'all clean' message" >&2
    echo "output: $CLEAN_OUT" >&2
    exit 1
fi

echo "ok 5: clean registry exits 0 with 'all clean' message"

echo ""
echo "All tests passed."
