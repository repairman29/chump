#!/usr/bin/env bash
# scripts/ci/test-auth-freshness-watchdog.sh — RESILIENT-056
#
# Regression tests for auth freshness safety net:
#   1. oauth-token-refresh.sh writes expires_at from claudeAiOauth.expiresAt
#   2. infra-watcher check-auth-freshness emits kind=auth_token_stale
#      when token file mtime is stale (condition a)
#   3. check-auth-freshness emits auth_token_stale when expires_at is
#      within the warn window (condition b)
#   4. check-auth-freshness emits auth_token_stale when repeated
#      oauth_token_refresh_failed events appear (condition c)
#   5. operator-recall AUTH_DEAD fires on auth_token_stale events
#   6. operator-recall AUTH_DEAD fires on repeated oauth_token_refresh_failed
#
# Run from repo root: bash scripts/ci/test-auth-freshness-watchdog.sh

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

INFRA_WATCHER="${REPO_ROOT}/scripts/coord/infra-watcher-loop.sh"
OPERATOR_RECALL="${REPO_ROOT}/scripts/dispatch/operator-recall.sh"
OAUTH_REFRESH="${REPO_ROOT}/scripts/coord/oauth-token-refresh.sh"

# ── Test 1: oauth-token-refresh.sh writes expires_at field ──────────────────
# Verify the script's Python parsing block handles expiresAt in the blob and
# that the token JSON includes the expires_at key when present.

# We test the parsing logic directly by inspecting the script source rather
# than calling security(1) (not available in CI sandboxes). The script extracts
# expires_at via python3 and writes it as "expires_at" in the JSON.

if grep -q 'expiresAt\|expires_at' "$OAUTH_REFRESH" 2>/dev/null; then
    pass "oauth-token-refresh.sh references expiresAt/expires_at (L3 extraction present)"
else
    fail "oauth-token-refresh.sh does not reference expiresAt or expires_at — L3 extraction missing"
fi

if grep -q '"expires_at"' "$OAUTH_REFRESH" 2>/dev/null; then
    pass "oauth-token-refresh.sh writes expires_at field into token JSON"
else
    fail "oauth-token-refresh.sh does not write expires_at field into token JSON"
fi

# ── Test 2: stale mtime → auth_token_stale event ────────────────────────────
_amb="${SANDBOX}/ambient-mtime.jsonl"
_tok="${SANDBOX}/oauth-token-stale.json"

# Write a token file with a timestamp 30 min in the past
printf '{"token":"sk-ant-oat01-test","written_at":"2026-05-01T00:00:00Z","source":"test"}\n' > "$_tok"
# Touch the file mtime to 30 minutes ago (1800 seconds)
touch -t "$(date -v -1800S +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$_tok" 2>/dev/null || \
    python3 -c "import os, time; os.utime('$_tok', (time.time()-1800, time.time()-1800))"

(
    export CHUMP_OAUTH_TOKEN_FILE="$_tok"
    export CHUMP_AMBIENT_LOG="$_amb"
    export CHUMP_AUTH_STALE_MTIME_S=600        # 10 min — file is 30 min old, should fire
    export CHUMP_AUTH_EXPIRY_WARN_S=600
    export CHUMP_AUTH_REFRESH_FAIL_THRESHOLD=99  # disable c-condition for this test
    export REPO_ROOT="$SANDBOX"
    bash "$INFRA_WATCHER" check-auth-freshness 2>/dev/null || true
)

if grep -q '"kind":"auth_token_stale"' "$_amb" 2>/dev/null; then
    pass "check-auth-freshness emits auth_token_stale when mtime is stale"
else
    fail "check-auth-freshness did NOT emit auth_token_stale for stale mtime"
fi

if grep -q '"reason":"mtime_stale"' "$_amb" 2>/dev/null || \
   python3 -c "
import json, sys
for line in open('$_amb'):
    try:
        d = json.loads(line)
        if d.get('kind') == 'auth_token_stale' and 'mtime_stale' in d.get('reason', ''):
            sys.exit(0)
    except: pass
sys.exit(1)
" 2>/dev/null; then
    pass "auth_token_stale reason field contains 'mtime_stale'"
else
    fail "auth_token_stale reason field missing 'mtime_stale'"
fi

# ── Test 3: imminent expires_at → auth_token_stale event ────────────────────
_amb3="${SANDBOX}/ambient-expiry.jsonl"
_tok3="${SANDBOX}/oauth-token-expiry.json"

# Token that expires in 2 minutes from now (within the 10-min warn window)
_expiry_epoch=$(( $(date +%s) + 120 ))
# Represent as ISO-8601 string
_expiry_iso="$(python3 -c "from datetime import datetime, timezone; print(datetime.fromtimestamp(${_expiry_epoch}, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || date -u -r "$_expiry_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-06-02T12:00:00Z")"
printf '{"token":"sk-ant-oat01-fresh","written_at":"2026-06-02T17:00:00Z","source":"test","expires_at":"%s"}\n' \
    "$_expiry_iso" > "$_tok3"
# File is brand-new (mtime OK) so only expiry condition should fire
touch "$_tok3"

(
    export CHUMP_OAUTH_TOKEN_FILE="$_tok3"
    export CHUMP_AMBIENT_LOG="$_amb3"
    export CHUMP_AUTH_STALE_MTIME_S=9999       # very high — don't trigger mtime condition
    export CHUMP_AUTH_EXPIRY_WARN_S=600        # 10 min warn — token expires in 2 min → fires
    export CHUMP_AUTH_REFRESH_FAIL_THRESHOLD=99
    export REPO_ROOT="$SANDBOX"
    bash "$INFRA_WATCHER" check-auth-freshness 2>/dev/null || true
)

if grep -q '"kind":"auth_token_stale"' "$_amb3" 2>/dev/null; then
    pass "check-auth-freshness emits auth_token_stale when expires_at is imminent"
else
    fail "check-auth-freshness did NOT emit auth_token_stale for imminent expiry"
fi

if grep -q '"reason":"expiry_imminent"' "$_amb3" 2>/dev/null; then
    pass "auth_token_stale reason field contains 'expiry_imminent'"
else
    fail "auth_token_stale reason field missing 'expiry_imminent'"
fi

# ── Test 4: repeated refresh failures → auth_token_stale event ───────────────
_amb4="${SANDBOX}/ambient-failures.jsonl"
_tok4="${SANDBOX}/oauth-token-fresh.json"

# Write a fresh token (mtime OK, no expires_at) so only failure condition fires
printf '{"token":"sk-ant-oat01-fresh","written_at":"2026-06-02T17:00:00Z","source":"test"}\n' > "$_tok4"
touch "$_tok4"

# Inject 4 oauth_token_refresh_failed events into ambient (within the last 30 min)
_ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for i in 1 2 3 4; do
    printf '{"ts":"%s","kind":"oauth_token_refresh_failed","reason":"keychain_miss","prev_age_seconds":300}\n' \
        "$_ts_now" >> "$_amb4"
done

(
    export CHUMP_OAUTH_TOKEN_FILE="$_tok4"
    export CHUMP_AMBIENT_LOG="$_amb4"
    export CHUMP_AUTH_STALE_MTIME_S=9999
    export CHUMP_AUTH_EXPIRY_WARN_S=60         # very tight — no expires_at field, won't fire
    export CHUMP_AUTH_REFRESH_FAIL_THRESHOLD=3  # 4 events ≥ 3 → fires
    export CHUMP_AUTH_REFRESH_FAIL_WINDOW_S=3600
    export REPO_ROOT="$SANDBOX"
    bash "$INFRA_WATCHER" check-auth-freshness 2>/dev/null || true
)

if grep -q '"kind":"auth_token_stale"' "$_amb4" 2>/dev/null; then
    pass "check-auth-freshness emits auth_token_stale on repeated refresh failures"
else
    fail "check-auth-freshness did NOT emit auth_token_stale for repeated refresh failures"
fi

if grep -q '"reason":"repeated_refresh_failures"' "$_amb4" 2>/dev/null; then
    pass "auth_token_stale reason field contains 'repeated_refresh_failures'"
else
    fail "auth_token_stale reason field missing 'repeated_refresh_failures'"
fi

# ── Test 5: operator-recall AUTH_DEAD fires on auth_token_stale ──────────────
_amb5="${SANDBOX}/ambient-recall-stale.jsonl"
_recall_lock="${SANDBOX}/recall-locks"
mkdir -p "$_recall_lock"

# Inject an auth_token_stale event into ambient
_ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"auth_token_stale","reason":"mtime_stale","token_file":"/tmp/fake.json"}\n' \
    "$_ts_now" >> "$_amb5"

(
    export CHUMP_AMBIENT_LOG="$_amb5"
    export CHUMP_AUTH_TOKEN_STALE_WINDOW_SECS=3600
    export CHUMP_AUTH_STORM_RECALL_THRESHOLD=999   # disable old trigger
    export CHUMP_AUTH_REFRESH_FAIL_THRESHOLD=999   # disable middle trigger
    export REPO_ROOT="$SANDBOX"
    bash "$OPERATOR_RECALL" --check-only 2>/dev/null
) && _rc=0 || _rc=$?

if (( _rc != 0 )); then
    pass "operator-recall --check-only exits non-zero when auth_token_stale present (AUTH_DEAD)"
else
    fail "operator-recall --check-only did NOT exit non-zero for auth_token_stale — AUTH_DEAD not widened"
fi

# Also verify the recall event is emitted (non --check-only path)
_amb5b="${SANDBOX}/ambient-recall-stale-emit.jsonl"
printf '{"ts":"%s","kind":"auth_token_stale","reason":"mtime_stale","token_file":"/tmp/fake.json"}\n' \
    "$_ts_now" >> "$_amb5b"

(
    export CHUMP_AMBIENT_LOG="$_amb5b"
    export CHUMP_AUTH_TOKEN_STALE_WINDOW_SECS=3600
    export CHUMP_AUTH_STORM_RECALL_THRESHOLD=999
    export CHUMP_AUTH_REFRESH_FAIL_THRESHOLD=999
    export CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0   # no cooldown in test
    export REPO_ROOT="$SANDBOX"
    bash "$OPERATOR_RECALL" 2>/dev/null || true
)

if grep -q '"kind":"operator_recall"' "$_amb5b" 2>/dev/null && \
   grep -q '"condition":"AUTH_DEAD"' "$_amb5b" 2>/dev/null; then
    pass "operator-recall emits operator_recall with condition=AUTH_DEAD on auth_token_stale"
else
    fail "operator-recall did NOT emit condition=AUTH_DEAD for auth_token_stale"
fi

# ── Test 6: operator-recall AUTH_DEAD fires on repeated oauth_token_refresh_failed ──
_amb6="${SANDBOX}/ambient-recall-refresh.jsonl"
_ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for i in 1 2 3 4; do
    printf '{"ts":"%s","kind":"oauth_token_refresh_failed","reason":"keychain_miss"}\n' \
        "$_ts_now" >> "$_amb6"
done

(
    export CHUMP_AMBIENT_LOG="$_amb6"
    export CHUMP_AUTH_REFRESH_FAIL_THRESHOLD=3
    export CHUMP_AUTH_REFRESH_FAIL_WINDOW_SECS=3600
    export CHUMP_AUTH_TOKEN_STALE_WINDOW_SECS=1     # very short — no stale events → won't fire from test 5 path
    export CHUMP_AUTH_STORM_RECALL_THRESHOLD=999
    export CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0
    export REPO_ROOT="$SANDBOX"
    bash "$OPERATOR_RECALL" --check-only 2>/dev/null
) && _rc6=0 || _rc6=$?

if (( _rc6 != 0 )); then
    pass "operator-recall --check-only exits non-zero on repeated oauth_token_refresh_failed"
else
    fail "operator-recall --check-only did NOT exit non-zero for repeated oauth_token_refresh_failed"
fi

# ── Test 7: EVENT_REGISTRY.yaml registers auth_token_stale ──────────────────
_registry="${REPO_ROOT}/docs/observability/EVENT_REGISTRY.yaml"
if grep -q '"kind":"auth_token_stale"\|kind: auth_token_stale' "$_registry" 2>/dev/null; then
    pass "EVENT_REGISTRY.yaml contains auth_token_stale registration"
else
    fail "EVENT_REGISTRY.yaml missing auth_token_stale entry"
fi

# ── Test 8: check-auth-freshness is included in tick cycle ──────────────────
if grep -q 'cmd_check_auth_freshness\|check-auth-freshness' "$INFRA_WATCHER" 2>/dev/null && \
   grep -A20 'cmd_tick()' "$INFRA_WATCHER" 2>/dev/null | grep -q 'check_auth_freshness\|check-auth-freshness'; then
    pass "infra-watcher-loop.sh includes check-auth-freshness in tick cycle"
else
    fail "infra-watcher-loop.sh does NOT include check-auth-freshness in tick cycle"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
