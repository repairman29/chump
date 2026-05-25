#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# test-gap-list-done-format.sh — EFFECTIVE-024: done gaps show closed-pr + closed-date
#
# Tests:
#   1. Human output: [done] GAP-ID — title (P/e) → #PR merged YYYY-MM-DD
#   2. JSON output: done gap rows include closed_pr and closed_date fields

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Locate the chump binary
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    for candidate in \
        "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" \
        "$REPO_ROOT/target/release/chump" \
        "$(command -v chump 2>/dev/null || true)"; do
        if [[ -x "$candidate" ]]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
[[ -n "$CHUMP_BIN" ]] || fail "chump binary not found; set CHUMP_BIN or build first"

TMP="$(mktemp -d -t test-gap-list-done.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Bootstrap a minimal state.db via python3
DB="$TMP/state.db"
python3 - <<PYEOF
import sqlite3, os

db = sqlite3.connect("$DB")
db.execute("""
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'P1',
    effort TEXT NOT NULL DEFAULT 's',
    status TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    source_doc TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0,
    closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '',
    closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER,
    skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '',
    preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '',
    required_model TEXT NOT NULL DEFAULT ''
)
""")
db.execute("""
CREATE TABLE leases (
    session_id TEXT PRIMARY KEY,
    gap_id TEXT NOT NULL DEFAULT '',
    paths TEXT NOT NULL DEFAULT '',
    taken_at INTEGER NOT NULL DEFAULT 0,
    expires_at INTEGER NOT NULL DEFAULT 0,
    heartbeat_at INTEGER NOT NULL DEFAULT 0,
    purpose TEXT NOT NULL DEFAULT ''
)
""")
db.execute("""
CREATE TABLE IF NOT EXISTS gap_counters (
    domain TEXT PRIMARY KEY,
    next_seq INTEGER NOT NULL DEFAULT 1
)
""")
# Insert a done gap with closed_pr and closed_date
db.execute("""
INSERT INTO gaps (id, domain, title, status, priority, effort, closed_pr, closed_date, acceptance_criteria)
VALUES ('TEST-001', 'TEST', 'fixed the thing', 'done', 'P1', 'xs', 1701, '2026-04-15', '1. Thing is fixed and tests pass')
""")
# Insert a done gap with only closed_pr (no closed_date)
db.execute("""
INSERT INTO gaps (id, domain, title, status, priority, effort, closed_pr, closed_date, acceptance_criteria)
VALUES ('TEST-002', 'TEST', 'another fix', 'done', 'P2', 's', 1702, '', '1. Another fix ships')
""")
# Insert an open gap (should NOT have → suffix)
db.execute("""
INSERT INTO gaps (id, domain, title, status, priority, effort, acceptance_criteria)
VALUES ('TEST-003', 'TEST', 'pending work', 'open', 'P1', 'm', '1. Work is done')
""")
db.commit()
db.close()
PYEOF

export CHUMP_STATE_DB="$DB"

# ── Test 1: Human format — done gap shows → #PR merged YYYY-MM-DD ────────────
OUT1="$("$CHUMP_BIN" gap list --status done --include-test-domains 2>/dev/null || true)"

# TEST-001 should show: [done] TEST-001 — fixed the thing (P1/xs) → #1701 merged 2026-04-15
if echo "$OUT1" | grep -qE '\[done\] TEST-001 — fixed the thing \(P1/xs\) → #1701 merged 2026-04-15'; then
    pass "Test 1a: TEST-001 shows '→ #1701 merged 2026-04-15'"
else
    fail "Test 1a: expected '→ #1701 merged 2026-04-15' in output. Got: $(echo "$OUT1" | grep TEST-001 || echo '(no match)')"
fi

# TEST-002 should show: → #1702 merged (no date)
if echo "$OUT1" | grep -qE '\[done\] TEST-002 — another fix \(P2/s\) → #1702 merged$'; then
    pass "Test 1b: TEST-002 shows '→ #1702 merged' (no date)"
else
    fail "Test 1b: expected '→ #1702 merged' for TEST-002. Got: $(echo "$OUT1" | grep TEST-002 || echo '(no match)')"
fi

# ── Test 2: JSON output — closed_pr and closed_date present for done gaps ──────
OUT2="$("$CHUMP_BIN" gap list --status done --json --include-test-domains 2>/dev/null || true)"

if echo "$OUT2" | python3 -c "
import json, sys
gaps = json.load(sys.stdin)
t1 = next((g for g in gaps if g['id'] == 'TEST-001'), None)
assert t1 is not None, 'TEST-001 not found in JSON'
assert t1.get('closed_pr') == 1701, f'closed_pr={t1.get(\"closed_pr\")} want 1701'
assert t1.get('closed_date') == '2026-04-15', f'closed_date={t1.get(\"closed_date\")} want 2026-04-15'
" 2>/dev/null; then
    pass "Test 2: JSON output includes closed_pr=1701 and closed_date='2026-04-15' for TEST-001"
else
    fail "Test 2: JSON missing closed_pr/closed_date. Output: ${OUT2:0:300}"
fi

echo ""
echo "All EFFECTIVE-024 done-format checks passed (3/3)."
