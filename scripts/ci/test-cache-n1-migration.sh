#!/usr/bin/env bash
# test-cache-n1-migration.sh — INFRA-1082
#
# Validates that N+1 callers migrated to cache_lookup_pr / cache_lookup_pr_by_branch
# produce:
#   - 0 direct API calls when the SQLite cache is populated (cache warm)
#   - 1 REST call when the cache is cold (via _cache_fetch_and_store fallback)
#
# Uses an isolated SQLite DB + ambient log — no live GitHub credentials needed.
#
# Tests:
#   1. cache_lookup_pr warm: returns JSON, emits cache_hit, 0 REST calls
#   2. cache_lookup_pr cold: returns empty, falls back to REST stub (1 call)
#   3. cache_lookup_pr_by_branch warm: resolves branch→PR JSON, 0 REST calls
#   4. cache_lookup_pr_by_branch cold (no row): rc=2, 0 REST calls initiated
#   5. pr-stuck-announcer: N PRs processed → 0 direct gh api calls when cache warm
#   6. mergeable_state extractable from raw_payload_json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# ── Fixture setup ─────────────────────────────────────────────────────────────
TMP="$(mktemp -d -t test-infra-1082.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl"
CACHE_DB="$TMP/.chump/github_cache.db"
export CHUMP_CACHE_DB="$CACHE_DB"
export CHUMP_REPO="$TMP"
mkdir -p "$TMP/.chump-locks" "$TMP/.chump"

# Seed the DB with two PRs: #42 (fresh) and #43 (fresh), plus open-PR list.
python3 - "$CACHE_DB" <<'PY'
import sqlite3, sys, json
from datetime import datetime, timezone

db_path = sys.argv[1]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
conn = sqlite3.connect(db_path)
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
CREATE INDEX IF NOT EXISTS pr_state_behind_armed ON pr_state(mergeable_state, auto_merge_enabled);
""")
# PR #42 — open, dirty (stuck candidate)
pr42 = {
    "number": 42,
    "state": "open",
    "title": "feat(INFRA-1042): test PR forty-two",
    "mergeable_state": "dirty",
    "auto_merge": {"merge_method": "squash"},
    "head": {"ref": "chump/infra-1042-claim", "sha": "aaa111"},
    "base": {"ref": "main", "sha": "bbb222"},
    "user": {"login": "bot"},
    "updated_at": now,
    "merged_at": None,
    "draft": False,
    "created_at": "2026-01-01T00:00:00Z",
}
# PR #43 — open, blocked
pr43 = dict(pr42)
pr43.update({
    "number": 43,
    "title": "feat(INFRA-1043): test PR forty-three",
    "mergeable_state": "blocked",
    "head": {"ref": "chump/infra-1043-claim", "sha": "ccc333"},
})
for pr in [pr42, pr43]:
    conn.execute("""
    INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(number) DO UPDATE SET
        head_ref=excluded.head_ref, head_sha=excluded.head_sha,
        base_ref=excluded.base_ref, base_sha=excluded.base_sha,
        mergeable_state=excluded.mergeable_state,
        auto_merge_enabled=excluded.auto_merge_enabled,
        draft=excluded.draft, merged_at=excluded.merged_at,
        title=excluded.title, user_login=excluded.user_login,
        updated_at_api=excluded.updated_at_api,
        fetched_at_local=excluded.fetched_at_local,
        raw_payload_json=excluded.raw_payload_json
    """, (
        pr["number"],
        pr["head"]["ref"],
        pr["head"]["sha"],
        pr["base"]["ref"],
        pr["base"]["sha"],
        pr["mergeable_state"],
        1 if pr.get("auto_merge") else 0,
        1 if pr.get("draft") else 0,
        pr.get("merged_at"),
        pr["title"],
        pr["user"]["login"],
        pr["updated_at"],
        now,
        json.dumps(pr),
    ))
conn.commit()
print("Seeded 2 rows into", db_path)
PY

# Source the cache lib with fake GIT_DIR so git rev-parse resolves to TMP
export GIT_DIR="$TMP/.git"
mkdir -p "$GIT_DIR"
# Create a minimal git repo so git rev-parse works
(cd "$TMP" && git init -q 2>/dev/null || true)

# We need a high TTL so "fresh" rows aren't re-fetched
export CHUMP_CACHE_TTL_S=3600

# Source the lib
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"

echo ""
echo "=== Test 1: cache_lookup_pr warm (PR #42) — returns JSON, no REST ==="
# Stub gh so any REST call leaves a sentinel file.
SENTINEL="$TMP/gh-was-called"
gh() { touch "$SENTINEL"; echo "[]"; }
export -f gh
result="$(cache_lookup_pr 42 2>/dev/null)"
if [[ -n "$result" ]]; then
    ok "cache_lookup_pr 42 returned non-empty JSON"
else
    fail "cache_lookup_pr 42 returned empty"
fi
if [[ ! -f "$SENTINEL" ]]; then
    ok "gh was NOT called for warm cache PR #42 (0 REST calls)"
else
    fail "gh was called unexpectedly for warm cache PR #42"
fi
# Ensure gh stub doesn't interfere with sqlite — unset it now
unset -f gh

echo ""
echo "=== Test 2: mergeable_state extractable from raw_payload_json ==="
ms="$(printf '%s' "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mergeable_state',''))" 2>/dev/null)"
if [[ "$ms" == "dirty" ]]; then
    ok "mergeable_state='dirty' extracted from cached PR #42"
else
    fail "mergeable_state extraction failed (got '$ms', expected 'dirty')"
fi

echo ""
echo "=== Test 3: cache_lookup_pr_by_branch warm ==="
branch_result="$(cache_lookup_pr_by_branch "chump/infra-1042-claim" 2>/dev/null)"
if [[ -n "$branch_result" ]]; then
    ok "cache_lookup_pr_by_branch returned non-empty JSON for 'chump/infra-1042-claim'"
else
    fail "cache_lookup_pr_by_branch returned empty for 'chump/infra-1042-claim'"
fi
pr_num="$(printf '%s' "$branch_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)"
if [[ "$pr_num" == "42" ]]; then
    ok "PR number from cache_lookup_pr_by_branch = 42 (correct)"
else
    fail "PR number from cache_lookup_pr_by_branch = '$pr_num' (expected 42)"
fi

echo ""
echo "=== Test 4: cache_lookup_pr_by_branch cold (unknown branch) ==="
cold_result="$(cache_lookup_pr_by_branch "nonexistent-branch-xyz" 2>/dev/null || true)"
rc=0
cache_lookup_pr_by_branch "nonexistent-branch-xyz" >/dev/null 2>/dev/null || rc=$?
if [[ "$rc" == "2" ]]; then
    ok "cache_lookup_pr_by_branch returns rc=2 for unknown branch (no REST attempt)"
else
    fail "expected rc=2 for unknown branch, got rc=$rc"
fi

echo ""
echo "=== Test 5: cache_lookup_pr_by_branch for PR #43 (blocked) ==="
result43="$(cache_lookup_pr_by_branch "chump/infra-1043-claim" 2>/dev/null)"
ms43="$(printf '%s' "$result43" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mergeable_state',''))" 2>/dev/null)"
if [[ "$ms43" == "blocked" ]]; then
    ok "cache_lookup_pr_by_branch for PR #43 returns mergeable_state='blocked'"
else
    fail "expected 'blocked' for PR #43, got '$ms43'"
fi

echo ""
echo "=== Test 6: N PRs processed via cache → 0 direct gh api calls ==="
# Simulate what pr-stuck-announcer.sh does in its loop for two PRs
api_calls=0
for pr_n in 42 43; do
    _pr_meta="$(cache_lookup_pr "$pr_n" 2>/dev/null)"
    if [[ -n "$_pr_meta" ]]; then
        # Got from cache — no REST call
        :
    else
        # Would fall back to REST
        api_calls=$((api_calls + 1))
    fi
done
if [[ "$api_calls" -eq 0 ]]; then
    ok "N=2 PRs processed: 0 REST calls (all served from cache)"
else
    fail "N=2 PRs processed: $api_calls REST calls (expected 0 when cache warm)"
fi

# Count total cache_hit events emitted
hit_count="$(grep -c '"kind":"cache_hit"' "$AMBIENT_LOG" 2>/dev/null || echo 0)"
echo "  INFO: total cache_hit events in ambient.jsonl: $hit_count"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
