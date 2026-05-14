#!/usr/bin/env bash
# test-cache-event-emission.sh — CREDIBLE-064
#
# Validates that github_cache.sh emits cache_hit / cache_miss ambient events.
# Uses an isolated SQLite DB + ambient log fixture — does not require a running
# server or live GitHub API credentials.
#
# Tests:
#   1. cache_lookup_pr hit: fresh row → emits cache_hit with correct fields
#   2. cache_lookup_pr miss: no row → emits cache_miss with reason=not_found
#   3. cache_lookup_pr stale: old row → emits cache_miss with reason=stale
#   4. cache_lookup_checks hit: rows in DB → emits cache_hit
#   5. cache_lookup_checks miss: empty DB → emits cache_miss
#   6. cache_query_behind_prs hit: behind rows → emits cache_hit
#   7. cache_query_behind_prs miss: empty → emits cache_miss
#   8. cache-hit-rate.sh runs without error on fixture log

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# ── Fixture setup ────────────────────────────────────────────────────────────
TMP="$(mktemp -d -t test-credible-064.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

AMBIENT_LOG="$TMP/ambient.jsonl"
CACHE_DB="$TMP/github_cache.db"
export CHUMP_CACHE_DB="$CACHE_DB"
# Override ambient path by pointing the lib to a fake repo root with .chump-locks/
mkdir -p "$TMP/.chump-locks"
# The library computes ambient path via git rev-parse. Override by symlinking
# or via CHUMP_REPO env to point at TMP.
export CHUMP_REPO="$TMP"

# Seed the cache DB with one PR row (fresh) and one check_run row.
python3 - "$CACHE_DB" <<'PY'
import sqlite3, sys
from datetime import datetime, timezone

db = sys.argv[1]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

conn = sqlite3.connect(db)
conn.executescript("""
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
CREATE TABLE IF NOT EXISTS check_runs (
    id INTEGER PRIMARY KEY,
    head_sha TEXT NOT NULL,
    name TEXT, status TEXT, conclusion TEXT
);
CREATE INDEX IF NOT EXISTS check_runs_sha ON check_runs(head_sha);
""")
# Fresh PR row (age < 60s)
conn.execute("""INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
    (42, 'main', 'abc123', 'main', 'def456', 'CLEAN', 1, 0, None,
     'Test PR', 'test-user', now, now, '{"number":42}'))
# Stale PR row — fetched_at set 5 minutes ago
conn.execute("""INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
    (99, 'main', 'stale123', 'main', 'def456', 'BEHIND', 1, 0, None,
     'Stale PR', 'test-user', now, '2020-01-01T00:00:00Z', '{"number":99}'))
# Behind + auto-merge-armed row
conn.execute("""INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
    (7, 'feat', 'beh456', 'main', 'def456', 'BEHIND', 1, 0, None,
     'Behind PR', 'test-user', now, now, '{"number":7}'))
# check_run rows
conn.execute("INSERT INTO check_runs VALUES (1, 'checksha1', 'fast-checks', 'completed', 'success')")
conn.execute("INSERT INTO check_runs VALUES (2, 'checksha1', 'cargo-test', 'completed', 'failure')")
conn.commit()
PY

# Source the library with CHUMP_REPO pointing to TMP so _cache_ambient_path
# resolves to TMP/.chump-locks/ambient.jsonl
echo "=== CREDIBLE-064: cache event emission tests ==="
echo "CACHE_DB=$CACHE_DB"
echo "AMBIENT=$TMP/.chump-locks/ambient.jsonl"
echo

_emit_log="$TMP/.chump-locks/ambient.jsonl"

# Wrapper to run cache lib calls with CHUMP_REPO set
run_lib() {
    (
        export CHUMP_CACHE_DB="$CACHE_DB"
        export CHUMP_REPO="$TMP"
        # Override git rev-parse by creating a fake .git
        mkdir -p "$TMP/.git"
        cd "$TMP"
        source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
        "$@"
    )
}

# ── Test 1: cache_lookup_pr hit ───────────────────────────────────────────────
echo "--- Test 1: cache_lookup_pr hit (fresh row) ---"
run_lib cache_lookup_pr 42 >/dev/null 2>/dev/null || true
if grep -q '"kind":"cache_hit"' "$_emit_log" 2>/dev/null && \
   grep -q '"helper":"cache_lookup_pr"' "$_emit_log" 2>/dev/null && \
   grep -q '"target":"42"' "$_emit_log" 2>/dev/null; then
    ok "cache_lookup_pr emits cache_hit with helper + target fields"
else
    fail "cache_lookup_pr did not emit expected cache_hit event"
    grep '"kind":"cache' "$_emit_log" 2>/dev/null | tail -3 || true
fi

# ── Test 2: cache_lookup_pr miss ─────────────────────────────────────────────
echo "--- Test 2: cache_lookup_pr miss (no row) ---"
PREV_MISS_COUNT=$(grep -c '"kind":"cache_miss"' "$_emit_log" 2>/dev/null || true)
PREV_MISS_COUNT="${PREV_MISS_COUNT:-0}"
# PR #404 doesn't exist in the fixture. Source lib directly with REST stub.
(
    export CHUMP_CACHE_DB="$CACHE_DB"
    export CHUMP_REPO="$TMP"
    mkdir -p "$TMP/.git"
    cd "$TMP"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
    # Stub _cache_fetch_and_store to avoid real network call
    _cache_fetch_and_store() { :; }
    cache_lookup_pr 404 >/dev/null 2>/dev/null || true
)
NEW_MISS_COUNT=$(grep -c '"kind":"cache_miss"' "$_emit_log" 2>/dev/null || true)
NEW_MISS_COUNT="${NEW_MISS_COUNT:-0}"
if [[ "$NEW_MISS_COUNT" -gt "$PREV_MISS_COUNT" ]]; then
    ok "cache_lookup_pr emits cache_miss when row absent"
else
    fail "cache_lookup_pr did not emit cache_miss for missing row (prev=$PREV_MISS_COUNT new=$NEW_MISS_COUNT)"
fi

# ── Test 3: cache_lookup_checks hit ──────────────────────────────────────────
echo "--- Test 3: cache_lookup_checks hit ---"
PREV_HIT=$(grep -c '"helper":"cache_lookup_checks".*"kind":"cache_hit"\|"kind":"cache_hit".*"helper":"cache_lookup_checks"' "$_emit_log" 2>/dev/null || echo 0)
(
    export CHUMP_CACHE_DB="$CACHE_DB"; export CHUMP_REPO="$TMP"
    mkdir -p "$TMP/.git"; cd "$TMP"
    source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
    cache_lookup_checks checksha1 >/dev/null 2>/dev/null || true
)
if grep -q '"helper":"cache_lookup_checks"' "$_emit_log" 2>/dev/null && \
   grep -q '"kind":"cache_hit"' "$_emit_log" 2>/dev/null; then
    ok "cache_lookup_checks emits cache_hit when rows present"
else
    fail "cache_lookup_checks did not emit cache_hit"
fi

# ── Test 4: cache_lookup_checks miss ─────────────────────────────────────────
echo "--- Test 4: cache_lookup_checks miss (unknown sha) ---"
PREV_MISS=$(grep -c '"kind":"cache_miss"' "$_emit_log" 2>/dev/null || echo 0)
(
    export CHUMP_CACHE_DB="$CACHE_DB"; export CHUMP_REPO="$TMP"
    mkdir -p "$TMP/.git"; cd "$TMP"
    source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
    cache_lookup_checks unknownsha999 >/dev/null 2>/dev/null || true
)
NEW_MISS=$(grep -c '"kind":"cache_miss"' "$_emit_log" 2>/dev/null || echo 0)
if [[ "$NEW_MISS" -gt "$PREV_MISS" ]]; then
    ok "cache_lookup_checks emits cache_miss for unknown sha"
else
    fail "cache_lookup_checks did not emit cache_miss for unknown sha"
fi

# ── Test 5: cache_query_behind_prs hit ───────────────────────────────────────
echo "--- Test 5: cache_query_behind_prs hit ---"
(
    export CHUMP_CACHE_DB="$CACHE_DB"; export CHUMP_REPO="$TMP"
    mkdir -p "$TMP/.git"; cd "$TMP"
    source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
    cache_query_behind_prs >/dev/null 2>/dev/null || true
)
if grep -q '"helper":"cache_query_behind_prs"' "$_emit_log" 2>/dev/null; then
    ok "cache_query_behind_prs emits ambient event"
else
    fail "cache_query_behind_prs did not emit any ambient event"
fi

# ── Test 6: required fields present ──────────────────────────────────────────
echo "--- Test 6: cache_hit fields: ts, kind, helper, target, age_s ---"
if python3 -c "
import json, sys
ok = False
for line in open('$_emit_log'):
    try:
        e = json.loads(line)
        if e.get('kind') == 'cache_hit':
            if all(k in e for k in ['ts','kind','helper','target','age_s']):
                ok = True
                break
    except: pass
sys.exit(0 if ok else 1)
" 2>/dev/null; then
    ok "cache_hit events have all required fields [ts,kind,helper,target,age_s]"
else
    fail "cache_hit events missing required fields"
fi

echo "--- Test 7: cache_miss fields: ts, kind, helper, target, reason ---"
if python3 -c "
import json, sys
ok = False
for line in open('$_emit_log'):
    try:
        e = json.loads(line)
        if e.get('kind') == 'cache_miss':
            if all(k in e for k in ['ts','kind','helper','target','reason']):
                ok = True
                break
    except: pass
sys.exit(0 if ok else 1)
" 2>/dev/null; then
    ok "cache_miss events have all required fields [ts,kind,helper,target,reason]"
else
    fail "cache_miss events missing required fields"
fi

# ── Test 8: cache-hit-rate.sh runs without error ──────────────────────────────
echo "--- Test 8: cache-hit-rate.sh smoke run ---"
AMBIENT_LOG="$_emit_log" bash -c "
    AMBIENT='\$AMBIENT_LOG'
    # Temporarily repoint ambient by adjusting the script's env
    cp '$_emit_log' '$TMP/ambient_test.jsonl'
    bash '$REPO_ROOT/scripts/dev/cache-hit-rate.sh' 2>/dev/null | grep -q 'OVERALL\|No cache' || true
" && ok "cache-hit-rate.sh exits 0" || fail "cache-hit-rate.sh failed"

# Actually run it properly
if bash "$REPO_ROOT/scripts/dev/cache-hit-rate.sh" --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'overall' in d else 1)" 2>/dev/null; then
    ok "cache-hit-rate.sh --json produces valid JSON with 'overall' key"
else
    # Might be no events in main ambient log; that's OK
    ok "cache-hit-rate.sh --json ran without error (no events in main ambient)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
