#!/usr/bin/env bash
#
# test-ambient-glance-pr-cache-ttl.sh — INFRA-3855 regression test.
#
# chump gap reserve shells out to scripts/coord/chump-ambient-glance.sh
# --check-prs on every call. Before INFRA-3855, an empty title-match (the
# common case — a novel gap title matches no open PR) was indistinguishable
# from a cold cache, so the script fired a live `gh api .../pulls` REST
# refill on essentially every reserve: ~0.8-10s per call, and 9 reserves in
# a burst blew past a 2-minute filing budget.
#
# Fix (chump-ambient-glance.sh _pr_cache_fresh): gate the refill on the
# cache's actual age. Fresh cache + empty match => genuinely no overlap,
# skip the network round-trip. Stale/missing cache => refill once.
#
# This test proves that behavior with a fake `gh` on PATH that records
# whether it was invoked. It fails without the freshness gate because the
# old code called cache_refresh_open_prs (and therefore `gh`) unconditionally
# on every empty-match call.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GLANCE="$REPO_ROOT/scripts/coord/chump-ambient-glance.sh"
[[ -x "$GLANCE" ]] || GLANCE="bash $REPO_ROOT/scripts/coord/chump-ambient-glance.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/.chump"

# Fake `gh`: records an invocation marker, always "fails" (empty stdout) so
# any test that DOES expect a refill attempt doesn't need real network/auth.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "called: $*" >> "$CHUMP_TEST_GH_MARKER"
exit 1
EOF
chmod +x "$TMP/bin/gh"

seed_cache() {
    local fetched_at="$1"
    rm -f "$TMP/.chump/github_cache.db"
    sqlite3 "$TMP/.chump/github_cache.db" <<SQL
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
INSERT INTO pr_state VALUES (1, 'some-branch', 'deadbeef', 'main', 'cafebabe',
    'CLEAN', 0, 0, NULL, 'unrelated pr title', 'someone', '${fetched_at}', '${fetched_at}', '{}');
SQL
}

run_glance() {
    CHUMP_TEST_GH_MARKER="$TMP/gh-called.log" \
    PATH="$TMP/bin:$PATH" \
    CHUMP_REPO_ROOT="$TMP" \
    CHUMP_CACHE_DB="$TMP/.chump/github_cache.db" \
    CHUMP_AMBIENT_PR_CACHE_TTL_S=600 \
    $GLANCE --domain TESTDOM --title "novel-title-that-matches-nothing-$$" --check-prs
}

echo "=== chump-ambient-glance.sh PR-cache TTL tests (INFRA-3855) ==="

# ── Test 1: fresh cache + empty title match → NO gh call ────────────────────
echo "--- Test 1: fresh cache skips the network refill ---"
seed_cache "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$TMP/gh-called.log"
START=$(date +%s%N)
run_glance >/dev/null 2>&1 || true
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [[ ! -f "$TMP/gh-called.log" ]]; then
    ok "fresh cache: no gh invocation"
else
    fail "fresh cache: gh was invoked ($(cat "$TMP/gh-called.log"))"
fi
if [[ "$ELAPSED_MS" -lt 1000 ]]; then
    ok "fresh cache: single call completed in ${ELAPSED_MS}ms (<1000ms)"
else
    fail "fresh cache: single call took ${ELAPSED_MS}ms (>=1000ms)"
fi

# ── Test 2: stale cache + empty title match → refill IS attempted ──────────
echo "--- Test 2: stale cache still attempts one refill ---"
seed_cache "$(date -u -d '-3600 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3600S +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$TMP/gh-called.log"
run_glance >/dev/null 2>&1 || true
if [[ -f "$TMP/gh-called.log" ]]; then
    ok "stale cache: gh invocation attempted (refill path still live)"
else
    fail "stale cache: expected a gh invocation, saw none"
fi

# ── Test 3: batch of 10 reserves with a fresh cache stays well under budget ─
echo "--- Test 3: batch of 10 fresh-cache calls under 15s ---"
seed_cache "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$TMP/gh-called.log"
START=$(date +%s%N)
for _ in $(seq 1 10); do
    run_glance >/dev/null 2>&1 || true
done
END=$(date +%s%N)
BATCH_MS=$(( (END - START) / 1000000 ))
if [[ ! -f "$TMP/gh-called.log" ]]; then
    ok "batch of 10: no gh invocation across the whole batch"
else
    fail "batch of 10: gh was invoked ($(cat "$TMP/gh-called.log"))"
fi
if [[ "$BATCH_MS" -lt 15000 ]]; then
    ok "batch of 10: completed in ${BATCH_MS}ms (<15000ms)"
else
    fail "batch of 10: took ${BATCH_MS}ms (>=15000ms)"
fi

echo
echo "=== results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || { for f in "${FAILS[@]}"; do echo "  - $f"; done; exit 1; }
exit 0
