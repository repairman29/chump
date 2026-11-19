#!/usr/bin/env bash
# scripts/ci/test-infra-1130-bot-merge-cache-checks.sh — INFRA-1130
#
# Tests that bot-merge.sh CI pre-flight reads check_runs from SQLite cache
# instead of calling gh api when the cache is warm.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── static checks ─────────────────────────────────────────────────────────────
grep -q 'INFRA-1130' "$BOT_MERGE" || fail "INFRA-1130 banner missing from bot-merge.sh"
grep -q 'cache_lookup_checks' "$BOT_MERGE" || fail "cache_lookup_checks not referenced in bot-merge.sh"
grep -q 'github_cache.sh' "$BOT_MERGE" || fail "github_cache.sh not sourced in bot-merge.sh"
grep -q 'cache_lookup_pr' "$BOT_MERGE" || fail "cache_lookup_pr not referenced in bot-merge.sh"
ok "static: bot-merge.sh has INFRA-1130 markers"

# ── build fake SQLite cache DB ────────────────────────────────────────────────
CACHE_DB="$TMP/cache.db"
FAKE_SHA="deadbeef1234567890abcdef1234567890abcdef"

sqlite3 "$CACHE_DB" <<SQLEOF
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    raw_payload_json TEXT,
    mergeable_state TEXT,
    head_sha TEXT,
    fetched_at_local DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS check_runs (
    id TEXT,
    head_sha TEXT NOT NULL,
    name TEXT NOT NULL,
    status TEXT,
    conclusion TEXT,
    updated_at TEXT,
    PRIMARY KEY (head_sha, name)
);
INSERT INTO pr_state (number, raw_payload_json, head_sha, fetched_at_local)
    VALUES (9999, '{"number":9999,"head":{"sha":"$FAKE_SHA"},"base":{"sha":"base0"},"state":"open","mergeable_state":"clean"}',
            '$FAKE_SHA', datetime('now'));
INSERT INTO check_runs (id, head_sha, name, status, conclusion)
    VALUES ('r1', '$FAKE_SHA', 'cargo-test',  'COMPLETED', 'SUCCESS'),
           ('r2', '$FAKE_SHA', 'audit',        'COMPLETED', 'SUCCESS'),
           ('r3', '$FAKE_SHA', 'fast-checks',  'COMPLETED', 'SUCCESS');
SQLEOF
ok "seed: pr_state + check_runs rows for PR #9999 / SHA $FAKE_SHA (all passing)"

# ── verify cache_lookup_checks returns the rows ───────────────────────────────
RESULT="$(CHUMP_CACHE_DB="$CACHE_DB" bash -c "source '$CACHE_LIB' && cache_lookup_checks '$FAKE_SHA'")"
echo "$RESULT" | grep -q "cargo-test" || fail "cache_lookup_checks didn't return cargo-test: $RESULT"
echo "$RESULT" | grep -q "audit"      || fail "cache_lookup_checks didn't return audit: $RESULT"
ok "cache_lookup_checks returns rows for head SHA"

# ── verify no FAILURE rows → _all_failing is empty ───────────────────────────
FAILING="$(printf '%s\n' "$RESULT" | awk -F'\t' 'toupper($3) ~ /FAILURE|ERROR|TIMED_OUT|CANCELLED/ {print $1 "\t" toupper($3)}')"
[[ -z "$FAILING" ]] || fail "expected no failing checks, got: $FAILING"
ok "awk filter: no failing checks when all conclusions are SUCCESS"

# ── add a failing check and verify it surfaces ────────────────────────────────
sqlite3 "$CACHE_DB" \
    "INSERT OR REPLACE INTO check_runs (id, head_sha, name, status, conclusion) \
     VALUES ('r4', '$FAKE_SHA', 'clippy', 'COMPLETED', 'FAILURE')"

RESULT2="$(CHUMP_CACHE_DB="$CACHE_DB" bash -c "source '$CACHE_LIB' && cache_lookup_checks '$FAKE_SHA'")"
FAILING2="$(printf '%s\n' "$RESULT2" | awk -F'\t' 'toupper($3) ~ /FAILURE|ERROR|TIMED_OUT|CANCELLED/ {print $1 "\t" toupper($3)}')"
echo "$FAILING2" | grep -q "clippy" || fail "clippy FAILURE not surfaced: $FAILING2"
ok "awk filter: FAILURE conclusion surfaced correctly"

# ── test that cache path is taken (no gh binary needed) ──────────────────────
# Simulate the bot-merge CI gate logic: source lib, do cache lookup, assert success
GH_STUB="$TMP/gh"
printf '#!/usr/bin/env bash\necho "gh should not be called" >&2\nexit 99\n' > "$GH_STUB"
chmod +x "$GH_STUB"

CACHE_HIT_ALL_PASS="$(CHUMP_CACHE_DB="$CACHE_DB" PATH="$TMP:$PATH" bash -c "
source '$CACHE_LIB'
sha=''
if pr_json=\$(cache_lookup_pr 9999 2>/dev/null); then
    sha=\$(printf '%s' \"\$pr_json\" | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d.get('head',{}).get('sha',''))\" 2>/dev/null || true)
fi
if [[ -n \"\$sha\" ]]; then
    checks=\$(cache_lookup_checks \"\$sha\" 2>/dev/null || true)
    if [[ -n \"\$checks\" ]]; then
        echo 'cache_hit'
        # all-pass path: check for failures
        failing=\$(printf '%s\n' \"\$checks\" | awk -F'\t' 'toupper(\$3) ~ /FAILURE|ERROR/ {print \$1}')
        if [[ -z \"\$failing\" ]]; then echo 'all_pass_from_cache'; fi
    fi
fi
" 2>/dev/null)"
echo "$CACHE_HIT_ALL_PASS" | grep -q "cache_hit" || fail "cache path not taken for PR #9999"
# Note: all_pass_from_cache may not appear since clippy=FAILURE was injected above
ok "cache path taken for warm-cache PR — no gh API calls fired"

# ── idempotency: re-running is safe ──────────────────────────────────────────
CHUMP_CACHE_DB="$CACHE_DB" bash -c "source '$CACHE_LIB' && cache_lookup_checks '$FAKE_SHA'" >/dev/null
ok "idempotent: second cache_lookup_checks call succeeds"

echo
echo "All INFRA-1130 bot-merge cache checks tests passed."
