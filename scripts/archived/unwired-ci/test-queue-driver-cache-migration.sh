#!/usr/bin/env bash
# test-queue-driver-cache-migration.sh — INFRA-2186 (P2/s)
#
# Asserts the three cache helpers used by queue-driver.sh return the expected
# PR numbers from a synthetic .chump/github_cache.db WITHOUT touching `gh`.
#
# Regression covered: queue-driver was burning ~48 GraphQL pr-list calls per
# hour during multi-PR cascade-rebase waves (graphql_exhausted firing every
# 60s). Migration to webhook-cache helpers makes cascade + DIRTY scans cost 0
# GraphQL points when the cache is warm.
#
# Tests:
#   1. cache_query_behind_prs returns BEHIND+armed PR numbers only
#   2. cache_query_dirty_armed_prs returns DIRTY+armed PR numbers only
#   3. cache_query_open_non_draft_prs returns open non-draft (any state)
#   4. All three are silent (empty) on missing db (cache_miss path)
#   5. None of the helpers shell out to `gh` (verified by PATH-trapping)

set -euo pipefail

# Resolve repo root regardless of where the test is invoked from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Trap any accidental `gh` call. If the helpers call `gh`, this fake will
# print to stderr and exit 99 — caught by `set -e` and fails the test.
TMP_BIN="$(mktemp -d)"
cat > "$TMP_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "test-queue-driver-cache-migration: ERROR — helper unexpectedly invoked 'gh $*'" >&2
exit 99
EOF
chmod +x "$TMP_BIN/gh"
export PATH="$TMP_BIN:$PATH"

# Synthetic cache db — fake git root so _cache_db_path + _cache_ambient_path
# resolve to our fixture, not the real repo.
CACHE_DIR="$(mktemp -d)"
mkdir -p "$CACHE_DIR/.chump" "$CACHE_DIR/.chump-locks"
( cd "$CACHE_DIR" && git init -q && git config user.email t@t && git config user.name t )
CACHE_DB="$CACHE_DIR/.chump/github_cache.db"
export CHUMP_CACHE_DB="$CACHE_DB"
# Run helpers from inside the fake git root so _cache_ambient_path resolves there.
cd "$CACHE_DIR"

sqlite3 "$CACHE_DB" <<'SQL'
CREATE TABLE pr_state (
    number              INTEGER PRIMARY KEY,
    head_ref            TEXT,
    head_sha            TEXT,
    base_ref            TEXT,
    base_sha            TEXT,
    mergeable_state     TEXT,
    auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
    draft               INTEGER NOT NULL DEFAULT 0,
    merged_at           TEXT,
    title               TEXT,
    user_login          TEXT,
    updated_at_api      TEXT NOT NULL,
    fetched_at_local    TEXT NOT NULL,
    raw_payload_json    TEXT,
    merge_state_status  TEXT
);

-- Fixture: 5 PRs of varied states.
INSERT INTO pr_state VALUES (101, 'feat/a', 'sha101', 'main', 'sha000', 'BEHIND', 1, 0, NULL, 'BEHIND armed', 'op', '2026-05-29T21:00:00Z', '2026-05-29T21:00:00Z', '{}', 'BEHIND');
INSERT INTO pr_state VALUES (102, 'feat/b', 'sha102', 'main', 'sha000', 'DIRTY',  1, 0, NULL, 'DIRTY armed',  'op', '2026-05-29T21:00:00Z', '2026-05-29T21:00:00Z', '{}', 'DIRTY');
INSERT INTO pr_state VALUES (103, 'feat/c', 'sha103', 'main', 'sha000', 'CLEAN',  1, 0, NULL, 'CLEAN armed',  'op', '2026-05-29T21:00:00Z', '2026-05-29T21:00:00Z', '{}', 'CLEAN');
INSERT INTO pr_state VALUES (104, 'feat/d', 'sha104', 'main', 'sha000', 'BEHIND', 0, 0, NULL, 'BEHIND unarmed','op', '2026-05-29T21:00:00Z', '2026-05-29T21:00:00Z', '{}', 'BEHIND');
INSERT INTO pr_state VALUES (105, 'feat/e', 'sha105', 'main', 'sha000', 'CLEAN',  1, 1, NULL, 'draft',         'op', '2026-05-29T21:00:00Z', '2026-05-29T21:00:00Z', '{}', 'CLEAN');
INSERT INTO pr_state VALUES (106, 'feat/f', 'sha106', 'main', 'sha000', 'CLEAN',  1, 0, '2026-05-29T20:00:00Z', 'merged', 'op', '2026-05-29T21:00:00Z', '2026-05-29T21:00:00Z', '{}', 'CLEAN');
SQL

# shellcheck source=../coord/lib/github_cache.sh
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"

pass=0
fail=0

# ── Test 1: cache_query_behind_prs returns 101 only (BEHIND+armed; 104 unarmed) ──
got="$(cache_query_behind_prs | tr '\n' ',' | sed 's/,$//')"
if [[ "$got" == "101" ]]; then
    echo "PASS 1: cache_query_behind_prs returns BEHIND+armed only ($got)"
    pass=$((pass+1))
else
    echo "FAIL 1: cache_query_behind_prs got '$got' expected '101'"
    fail=$((fail+1))
fi

# ── Test 2: cache_query_dirty_armed_prs returns 102 only ──
got="$(cache_query_dirty_armed_prs | tr '\n' ',' | sed 's/,$//')"
if [[ "$got" == "102" ]]; then
    echo "PASS 2: cache_query_dirty_armed_prs returns DIRTY+armed only ($got)"
    pass=$((pass+1))
else
    echo "FAIL 2: cache_query_dirty_armed_prs got '$got' expected '102'"
    fail=$((fail+1))
fi

# ── Test 3: cache_query_open_non_draft_prs returns 101,102,103,104 (not 105 draft, not 106 merged) ──
got="$(cache_query_open_non_draft_prs | tr '\n' ',' | sed 's/,$//')"
if [[ "$got" == "101,102,103,104" ]]; then
    echo "PASS 3: cache_query_open_non_draft_prs excludes draft + merged ($got)"
    pass=$((pass+1))
else
    echo "FAIL 3: cache_query_open_non_draft_prs got '$got' expected '101,102,103,104'"
    fail=$((fail+1))
fi

# ── Test 4: missing db returns empty (cache_miss path) ──
rm -f "$CACHE_DB"
got="$(cache_query_behind_prs)$(cache_query_dirty_armed_prs)$(cache_query_open_non_draft_prs)"
if [[ -z "$got" ]]; then
    echo "PASS 4: helpers return empty silently on missing db (cache_miss path)"
    pass=$((pass+1))
else
    echo "FAIL 4: helpers returned non-empty '$got' on missing db"
    fail=$((fail+1))
fi

# ── Test 5: ambient.jsonl received cache_miss events (post Test 4) ──
amb="$CACHE_DIR/.chump-locks/ambient.jsonl"
if grep -q 'cache_query_open_non_draft_prs' "$amb" 2>/dev/null \
   && grep -q 'cache_query_dirty_armed_prs' "$amb" 2>/dev/null; then
    echo "PASS 5: cache_miss events emitted for both new helpers"
    pass=$((pass+1))
else
    echo "FAIL 5: missing cache_miss events in ambient.jsonl"
    cat "$amb" 2>/dev/null || echo "(no ambient file)"
    fail=$((fail+1))
fi

# Cleanup
rm -rf "$TMP_BIN" "$CACHE_DIR"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-queue-driver-cache-migration: ALL $pass tests passed"
    exit 0
else
    echo "test-queue-driver-cache-migration: $pass passed, $fail failed"
    exit 1
fi
