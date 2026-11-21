#!/usr/bin/env bash
# scripts/ci/test-fleet029-cache-overlap.sh — INFRA-1108
#
# Verifies bot-merge's FLEET-029 overlap scan (in chump-ambient-glance.sh)
# reads from .chump/github_cache.db first, falls back to gh pr list.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GLANCE="$REPO_ROOT/scripts/coord/chump-ambient-glance.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$GLANCE" ]] || fail "chump-ambient-glance.sh missing"
grep -q 'INFRA-1108' "$GLANCE" || fail "INFRA-1108 banner missing"
grep -q 'github_cache.db' "$GLANCE" || fail "doesn't reference github_cache.db"
grep -q 'pr_state' "$GLANCE" || fail "doesn't query pr_state"
grep -q 'gh pr list' "$GLANCE" || fail "lost the gh pr list fallback"
ok "static: cache-first SELECT + gh pr list fallback both present"

# Live functional: prime cache with matching PRs, run --check-prs --title, assert it reports cache hit
CACHE_DB="$TMP/cache.db"
sqlite3 "$CACHE_DB" <<'SQL'
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT, auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
INSERT INTO pr_state VALUES (501,'x','sha501','main','sha-main','CLEAN',1,0,NULL,'feat(INFRA-X): demo overlap','u','t','t','{}');
INSERT INTO pr_state VALUES (502,'y','sha502','main','sha-main','CLEAN',1,0,NULL,'docs: unrelated','u','t','t','{}');
SQL

# Mock git rev-parse so glance finds our cache.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "rev-parse --show-toplevel" ]]; then
    echo "$TMP"
    exit 0
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$TMP/fakebin/git"

# Provide the cache lib at the expected relative path (TMP/scripts/coord/lib/)
mkdir -p "$TMP/scripts/coord/lib" "$TMP/.chump"
cp "$REPO_ROOT/scripts/coord/lib/github_cache.sh" "$TMP/scripts/coord/lib/" 2>/dev/null || \
    touch "$TMP/scripts/coord/lib/github_cache.sh"
mv "$CACHE_DB" "$TMP/.chump/github_cache.db"
CACHE_DB="$TMP/.chump/github_cache.db"

# Run glance with --check-prs --title matching one PR.
OUT=$(PATH="$TMP/fakebin:$PATH" CHUMP_CACHE_DB="$CACHE_DB" \
    bash "$GLANCE" --title "INFRA-X" --check-prs 2>&1 || true)

echo "$OUT" | grep -q "FLEET-029 cache hit" \
    || fail "expected cache hit banner, got: $OUT"
echo "$OUT" | grep -q "501 feat" \
    || fail "expected match for PR 501 in output: $OUT"
echo "$OUT" | grep -q "502" \
    && fail "should NOT match unrelated PR 502: $OUT"
ok "cache hit: matched 1 overlapping PR via pr_state, ignored unrelated"

echo
echo "All INFRA-1108 fleet029-cache-overlap tests passed."
