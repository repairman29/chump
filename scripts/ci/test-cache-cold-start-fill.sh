#!/usr/bin/env bash
# scripts/ci/test-cache-cold-start-fill.sh — INFRA-1106
#
# Verifies github-cache-reconcile.sh fills mergeable_state for cold-start
# pr_state rows via bounded per-PR REST fetches.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/github-cache-reconcile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Static check: the cold-start block exists
grep -q 'INFRA-1106' "$RECONCILE" || fail "INFRA-1106 banner missing"
grep -q 'CHUMP_CACHE_RECONCILE_MAX_FETCH' "$RECONCILE" \
    || fail "max-fetch budget env var missing"
grep -q '"kind": "cache_warmed"' "$RECONCILE" \
    || fail "cache_warmed emit missing"
grep -q "mergeable_state IS NULL OR mergeable_state = ''" "$RECONCILE" \
    || fail "cold-row SELECT predicate missing"
ok "INFRA-1106 cold-start block + budget knob + emit kind + SELECT predicate all wired"

# EVENT_REGISTRY
grep -q 'kind: cache_warmed' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "EVENT_REGISTRY missing cache_warmed"
ok "EVENT_REGISTRY.yaml registers cache_warmed"

# Functional fixture: build a fake repo with synthetic pr_state rows, stub
# gh via PATH, run reconcile in apply mode, assert mergeable_state filled.
FAKE_REPO="$TMP/fake"
mkdir -p "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks"
cd "$FAKE_REPO"
git init -q
git config user.email t@t.test && git config user.name t
echo x > x && git add . && git commit -qm init

CACHE="$FAKE_REPO/.chump/github_cache.db"
AMB="$FAKE_REPO/.chump-locks/ambient.jsonl"

# Seed cache with 2 cold rows (mergeable_state empty) + 1 fully-populated row.
sqlite3 "$CACHE" <<'SQL'
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
INSERT INTO pr_state VALUES (101,'feat-a','sha101','main','sha-main','',0,0,NULL,'PR 101','user1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','{}');
INSERT INTO pr_state VALUES (102,'feat-b','sha102','main','sha-main','',1,0,NULL,'PR 102','user2','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','{}');
INSERT INTO pr_state VALUES (103,'feat-c','sha103','main','sha-main','CLEAN',1,0,NULL,'PR 103','user3','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','{}');
SQL

# Fake gh: rate_limit/repo-view + the two per-PR fetches return mergeable_state
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    echo "test/repo"; exit 0
fi
if [[ "${1:-}" == "api" ]]; then
    case "$2" in
        */pulls/101)
            echo '{"number":101,"head":{"ref":"feat-a","sha":"sha101"},"base":{"ref":"main","sha":"sha-main"},"mergeable_state":"BEHIND","auto_merge":null,"draft":false,"merged_at":null,"title":"PR 101","user":{"login":"user1"},"updated_at":"2026-05-14T00:00:00Z"}'
            exit 0 ;;
        */pulls/102)
            echo '{"number":102,"head":{"ref":"feat-b","sha":"sha102"},"base":{"ref":"main","sha":"sha-main"},"mergeable_state":"DIRTY","auto_merge":{"merge_method":"squash"},"draft":false,"merged_at":null,"title":"PR 102","user":{"login":"user2"},"updated_at":"2026-05-14T00:00:00Z"}'
            exit 0 ;;
        */pulls?state=open*)
            # Bulk list returns empty mergeable_state (matches real GitHub behavior).
            echo '[]'
            exit 0 ;;
    esac
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"

PATH="$TMP/fakebin:$PATH" \
    CHUMP_CACHE_DB="$CACHE" \
    CHUMP_AMBIENT_LOG="$AMB" \
    bash "$RECONCILE" 2>&1 | tail -5

# Assert: rows 101 and 102 now have mergeable_state filled.
RESULT=$(sqlite3 "$CACHE" "SELECT number || ':' || mergeable_state FROM pr_state ORDER BY number" 2>&1)
echo "$RESULT" | grep -q "101:BEHIND" || fail "PR 101 not warmed: $RESULT"
echo "$RESULT" | grep -q "102:DIRTY" || fail "PR 102 not warmed: $RESULT"
echo "$RESULT" | grep -q "103:CLEAN" || fail "PR 103 (was not cold) shouldn't change: $RESULT"
ok "cold rows 101+102 warmed via REST fetch; warm row 103 left alone"

# Assert: two kind=cache_warmed events emitted.
WARMED=$(grep -c '"kind":"cache_warmed"' "$AMB" 2>/dev/null || echo 0)
[[ "$WARMED" -eq 2 ]] || fail "expected 2 cache_warmed events, got $WARMED in $(cat "$AMB" 2>/dev/null)"
ok "emitted 2 kind=cache_warmed events (one per warmed row)"

# Assert: budget knob honored — set max-fetch=0, run again on the same cold cache.
sqlite3 "$CACHE" "UPDATE pr_state SET mergeable_state = '' WHERE number IN (101, 102)" >/dev/null
> "$AMB"
PATH="$TMP/fakebin:$PATH" \
    CHUMP_CACHE_DB="$CACHE" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_CACHE_RECONCILE_MAX_FETCH=0 \
    bash "$RECONCILE" 2>&1 >/dev/null
RESULT2=$(sqlite3 "$CACHE" "SELECT mergeable_state FROM pr_state WHERE number=101" 2>&1)
[[ -z "$RESULT2" ]] || fail "MAX_FETCH=0 should skip warming, but ms='$RESULT2'"
ok "CHUMP_CACHE_RECONCILE_MAX_FETCH=0 disables warming"

echo
echo "All INFRA-1106 cold-start-fill tests passed."
