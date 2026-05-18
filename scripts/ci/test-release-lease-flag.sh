#!/usr/bin/env bash
# test-release-lease-flag.sh — INFRA-1026: chump --release --lease <SESSION_ID>
#
# Tests:
#   1. chump --release --lease <ID> releases the named session, not current
#   2. chump --release --lease <NONEXISTENT> exits 1 with "no such session"
#   3. chump --release (no --lease) does NOT print "no such session"
#   4. chump --release --session-id=<ID> still works (existing equals-form)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    for candidate in \
        "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" \
        "$REPO_ROOT/target/release/chump" \
        "$(command -v chump 2>/dev/null || true)"; do
        if [[ -x "$candidate" ]]; then CHUMP_BIN="$candidate"; break; fi
    done
fi
[[ -n "$CHUMP_BIN" ]] || fail "chump binary not found; build first or set CHUMP_BIN"

TMP="$(mktemp -d -t test-release-lease.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# agent_lease uses CHUMP_REPO to find .chump-locks/
# Set it so the binary reads our isolated test lock directory.
export CHUMP_REPO="$TMP"
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"

DB="$TMP/.chump/state.db"
mkdir -p "$TMP/.chump"
python3 - <<PYEOF
import sqlite3
db = sqlite3.connect("$DB")
db.execute("""
CREATE TABLE IF NOT EXISTS leases (
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
CREATE TABLE IF NOT EXISTS gaps (
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
CREATE TABLE IF NOT EXISTS gap_counters (
    domain TEXT PRIMARY KEY,
    next_seq INTEGER NOT NULL DEFAULT 1
)
""")
db.commit()
db.close()
PYEOF
export CHUMP_STATE_DB="$DB"

# Write fake session lock file
FAKE_SESSION="claim-infra-995-44750-1778698509"
FAKE_LOCK="$LOCK_DIR/${FAKE_SESSION}.json"
python3 -c "
import json, time
now_ts = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
far_ts = '2099-01-01T00:00:00Z'
lock = {
    'session_id': '$FAKE_SESSION',
    'gap_id': 'INFRA-995',
    'paths': [],
    'taken_at': now_ts,
    'expires_at': far_ts,
    'heartbeat_at': now_ts,
    'purpose': 'gap:INFRA-995'
}
with open('$FAKE_LOCK', 'w') as f:
    json.dump(lock, f)
"

# ── Test 1: --release --lease <ID> releases the named session ─────────────────
OUT1="$("$CHUMP_BIN" --release --lease "$FAKE_SESSION" 2>&1 || true)"
if echo "$OUT1" | grep -q "released session_id=$FAKE_SESSION"; then
    pass "Test 1: --release --lease <ID> releases named session"
else
    fail "Test 1: expected 'released session_id=$FAKE_SESSION'. Got: $OUT1"
fi

# Lock file should be removed
if [[ ! -f "$FAKE_LOCK" ]]; then
    pass "Test 1: lock file removed after --release --lease"
else
    fail "Test 1: lock file still exists at $FAKE_LOCK"
fi

# ── Test 2: --release --lease <NONEXISTENT> → exit 1 "no such session" ────────
RC2=0
OUT2="$("$CHUMP_BIN" --release --lease "claim-nonexistent-00000" 2>&1)" || RC2=$?
if [[ "$RC2" -eq 1 ]] && echo "$OUT2" | grep -q "no such session"; then
    pass "Test 2: --release --lease <nonexistent> exits 1 with 'no such session'"
else
    fail "Test 2: expected exit 1 + 'no such session'. Got rc=$RC2 output: $OUT2"
fi

# ── Test 3: --release (no --lease) does NOT print "no such session" ───────────
OUT3="$("$CHUMP_BIN" --release 2>&1 || true)"
if echo "$OUT3" | grep -q "no such session"; then
    fail "Test 3: --release without --lease printed 'no such session' (should only apply to explicit --lease)"
else
    pass "Test 3: --release without --lease does not print 'no such session'"
fi

# ── Test 4: --session-id=<ID> form still works ────────────────────────────────
SESSION2="claim-test-session-two-12345"
LOCK2="$LOCK_DIR/${SESSION2}.json"
python3 -c "
import json, time
now_ts = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
lock = {
    'session_id': '$SESSION2',
    'gap_id': 'TEST-002',
    'paths': [],
    'taken_at': now_ts,
    'expires_at': '2099-01-01T00:00:00Z',
    'heartbeat_at': now_ts,
    'purpose': 'test'
}
with open('$LOCK2', 'w') as f:
    json.dump(lock, f)
"

OUT4="$("$CHUMP_BIN" --release --session-id="$SESSION2" 2>&1 || true)"
if echo "$OUT4" | grep -q "released session_id=$SESSION2"; then
    pass "Test 4: --session-id=<ID> form releases named session"
else
    fail "Test 4: expected 'released session_id=$SESSION2'. Got: $OUT4"
fi

echo ""
echo "All INFRA-1026 release-lease-flag checks passed (5/5)."
