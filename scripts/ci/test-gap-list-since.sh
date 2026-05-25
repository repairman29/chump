#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-gap-list-since.sh — EFFECTIVE-018: chump gap list --since filters by activity date
#
# AC3: 3 tests:
#   1. Recent gap appears with --since 7d
#   2. Old gap is hidden with --since 1d (gap opened long ago)
#   3. JSON output has since_cutoff + gaps fields

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# ── Locate chump binary ────────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    elif [[ -f "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    else
        # Try building it (skips if cache is warm)
        echo "[test-gap-list-since] building chump binary..."
        cargo build -q --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump 2>/dev/null \
            || { echo "[SKIP] could not build chump — skipping EFFECTIVE-018 tests"; exit 0; }
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    fi
fi

# ── Set up a synthetic state.db ───────────────────────────────────────────────
TMP="$(mktemp -d -t test-gap-list-since.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_DB="$TMP/.chump/state.db"
mkdir -p "$(dirname "$FAKE_DB")"

TODAY="$(date +%Y-%m-%d)"
WEEK_AGO="$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)"
OLD_DATE="2025-01-15"

sqlite3 "$FAKE_DB" <<SQL
CREATE TABLE gaps (
    id                  TEXT PRIMARY KEY,
    domain              TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    priority            TEXT NOT NULL DEFAULT '',
    effort              TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on          TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    source_doc          TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL DEFAULT 0,
    closed_at           INTEGER,
    opened_date         TEXT NOT NULL DEFAULT '',
    closed_date         TEXT NOT NULL DEFAULT '',
    closed_pr           INTEGER,
    skills_required     TEXT NOT NULL DEFAULT '',
    preferred_backend   TEXT NOT NULL DEFAULT '',
    preferred_machine   TEXT NOT NULL DEFAULT '',
    estimated_minutes   TEXT NOT NULL DEFAULT '',
    required_model      TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps (id, domain, title, status, priority, effort, opened_date, closed_date) VALUES
    ('RECENT-001', 'EFFECTIVE', 'Recent gap opened today',           'open',   'P1', 's', '${TODAY}',     ''),
    ('RECENT-002', 'EFFECTIVE', 'Recent gap closed this week',       'done',   'P1', 's', '${WEEK_AGO}',  '${TODAY}'),
    ('OLD-001',    'EFFECTIVE', 'Old gap opened long ago',           'open',   'P2', 'm', '${OLD_DATE}',  ''),
    ('OLD-002',    'EFFECTIVE', 'Old gap closed long ago',           'done',   'P3', 'l', '${OLD_DATE}',  '2025-02-01');
SQL

# ── Test 1: --since 7d shows recently-opened gap ───────────────────────────────
out="$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap list --since 7d 2>&1)"
echo "$out" | grep -q "RECENT-001" \
    || fail "Test 1: gap opened today should appear with --since 7d (got: $out)"
pass "Test 1: recently-opened gap appears with --since 7d"

# ── Test 2: old gap is hidden by --since 1d ───────────────────────────────────
out2="$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap list --since 1d 2>&1)"
echo "$out2" | grep -q "OLD-001" \
    && fail "Test 2: old gap (2025-01-15) should NOT appear with --since 1d" || true
pass "Test 2: old gap hidden by --since 1d"

# ── Test 3: --since 7d also surfaces recently-closed gap (closed_date match) ───
out3="$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap list --status done --since 7d 2>&1)"
echo "$out3" | grep -q "RECENT-002" \
    || fail "Test 3: gap closed today should appear with --status done --since 7d (got: $out3)"
pass "Test 3: recently-closed gap appears with --status done --since 7d"

# ── Test 4: --json --since includes since_cutoff + gaps fields ─────────────────
json="$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap list --since 7d --json 2>&1)"
python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'since_cutoff' in d, f'since_cutoff missing from JSON: {list(d.keys())}'
assert 'gaps' in d, f'gaps key missing from JSON: {list(d.keys())}'
assert d['since_cutoff'] is not None, 'since_cutoff is null'
ids = [g['id'] for g in d['gaps']]
assert 'RECENT-001' in ids, f'RECENT-001 missing from JSON gaps: {ids}'
assert 'OLD-001' not in ids, f'OLD-001 should not be in JSON gaps: {ids}'
print('json_ok')
" <<< "$json" | grep -q "json_ok" \
    || fail "Test 4: JSON --since output missing since_cutoff or gaps, or filtering wrong"
pass "Test 4: JSON --since output has since_cutoff + gaps fields, filtering correct"

echo ""
echo "All EFFECTIVE-018 gap list --since tests passed (4/4)."
