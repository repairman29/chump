#!/usr/bin/env bash
# test-auth-freshness-watchdog.sh — RESILIENT-056
#
# End-to-end coverage for the auth freshness safety net:
#  1. oauth-token-refresh.sh writes expires_at from claudeAiOauth.expiresAt
#  2. infra-watcher-loop.sh check-oauth-freshness emits kind=auth_token_stale
#     when a token file is stale by mtime OR by expires_at
#  3. operator-recall.sh AUTH_DEAD fires on repeated oauth_token_refresh_failed
#     or auth_token_stale events, not only fleet_auth_storm+worker_exit
#
# Run from repo root: bash scripts/ci/test-auth-freshness-watchdog.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

mkdir -p "$SANDBOX/bin"
AMBIENT="$SANDBOX/ambient.jsonl"
TOKEN_FILE="$SANDBOX/oauth-token.json"

# ── Test 1: oauth-token-refresh.sh captures expires_at ─────────────────────

cat > "$SANDBOX/bin/security" <<'EOF'
#!/usr/bin/env bash
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-fresh","expiresAt":1999999999000}}\n'
EOF
chmod +x "$SANDBOX/bin/security"

cat > "$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "PONG"
exit 0
EOF
chmod +x "$SANDBOX/bin/claude"

PATH="$SANDBOX/bin:$PATH" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_OAUTH_TOKEN_FILE="$TOKEN_FILE" \
CHUMP_OAUTH_PLATFORM_OVERRIDE="Darwin" \
CHUMP_AUTH_MODE=oauth \
ANTHROPIC_API_KEY= \
bash "$REPO_ROOT/scripts/coord/oauth-token-refresh.sh" refresh-once >/dev/null 2>&1 || true

if grep -q '"expires_at":"1999999999000"' "$TOKEN_FILE" 2>/dev/null; then
    pass "oauth-token-refresh.sh writes expires_at from claudeAiOauth.expiresAt"
else
    fail "expires_at field missing or wrong in token file: $(cat "$TOKEN_FILE" 2>/dev/null)"
fi

# ── Test 2: check-oauth-freshness emits auth_token_stale on stale mtime ────
# infra-watcher-loop.sh hardcodes its ambient log to $REPO_ROOT/.chump-locks/
# ambient.jsonl (no CHUMP_AMBIENT_LOG override), so point REPO_ROOT at a
# sandbox dir with that layout pre-created.

mkdir -p "$SANDBOX/.chump-locks"
AMBIENT_LOOP="$SANDBOX/.chump-locks/ambient.jsonl"

: > "$AMBIENT_LOOP"
printf '{"token":"OLD","written_at":"2020-01-01T00:00:00Z","source":"test","expires_at":"1999999999000"}\n' > "$TOKEN_FILE"
touch -d "@$(( $(date +%s) - 3600 ))" "$TOKEN_FILE" 2>/dev/null \
    || touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null)" "$TOKEN_FILE" 2>/dev/null \
    || true

REPO_ROOT="$SANDBOX" \
CHUMP_OAUTH_TOKEN_FILE="$TOKEN_FILE" \
CHUMP_OAUTH_STALE_S=900 \
CHUMP_OAUTH_EXPIRY_WARN_S=600 \
bash "$REPO_ROOT/scripts/coord/infra-watcher-loop.sh" check-oauth-freshness >/dev/null 2>&1 || true

if grep -q '"kind":"auth_token_stale"' "$AMBIENT_LOOP" 2>/dev/null; then
    pass "check-oauth-freshness emits kind=auth_token_stale for a stale (mtime) token file"
else
    fail "kind=auth_token_stale not emitted for a stale mtime token file"
fi

# ── Test 3: check-oauth-freshness emits auth_token_stale on near-expiry ────

rm -f "$AMBIENT_LOOP"
_near_expiry_ms=$(( ($(date +%s) + 60) * 1000 ))  # expires in 60s, well under 10min warn
printf '{"token":"FRESH","written_at":"%s","source":"test","expires_at":"%d"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_near_expiry_ms" > "$TOKEN_FILE"
# mtime is "now" (fresh), so only the expiry signal should trip this.

REPO_ROOT="$SANDBOX" \
CHUMP_OAUTH_TOKEN_FILE="$TOKEN_FILE" \
CHUMP_OAUTH_STALE_S=900 \
CHUMP_OAUTH_EXPIRY_WARN_S=600 \
bash "$REPO_ROOT/scripts/coord/infra-watcher-loop.sh" check-oauth-freshness >/dev/null 2>&1 || true

if grep -q '"kind":"auth_token_stale"' "$AMBIENT_LOOP" 2>/dev/null && \
   grep -q '"reason":"expiry"' "$AMBIENT_LOOP" 2>/dev/null; then
    pass "check-oauth-freshness emits kind=auth_token_stale reason=expiry when expires_at is within CHUMP_OAUTH_EXPIRY_WARN_S even though mtime is fresh"
else
    fail "kind=auth_token_stale (reason=expiry) not emitted for a token near its claimed expiry"
fi

# ── Test 4: operator-recall AUTH_DEAD fires on repeated auth_token_stale ───

_amb4="$SANDBOX/ambient-recall-stale.jsonl"
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for i in 1 2; do
    printf '{"ts":"%s","kind":"auth_token_stale","token_file":"x","age_seconds":1000,"reason":"mtime"}\n' \
        "$_ts" >> "$_amb4"
done

_rc=0
CHUMP_AMBIENT_LOG="$_amb4" \
REPO_ROOT="$REPO_ROOT" \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
CHUMP_AUTH_STALE_RECALL_THRESHOLD=2 \
CHUMP_AUTH_STORM_RECALL_THRESHOLD=999 \
CHUMP_OAUTH_FAILURE_RECALL_THRESHOLD=999 \
"$REPO_ROOT/scripts/dispatch/operator-recall.sh" --check-only 2>/dev/null || _rc=$?

if (( _rc != 0 )); then
    pass "operator-recall --check-only exits 1 on repeated auth_token_stale"
else
    fail "operator-recall --check-only should exit 1 on repeated auth_token_stale but exited 0"
fi

_amb4e="$SANDBOX/ambient-recall-stale-emit.jsonl"
cp "$_amb4" "$_amb4e"
CHUMP_AMBIENT_LOG="$_amb4e" \
REPO_ROOT="$REPO_ROOT" \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
CHUMP_AUTH_STALE_RECALL_THRESHOLD=2 \
CHUMP_AUTH_STORM_RECALL_THRESHOLD=999 \
CHUMP_OAUTH_FAILURE_RECALL_THRESHOLD=999 \
"$REPO_ROOT/scripts/dispatch/operator-recall.sh" 2>/dev/null || true

if grep -q '"kind":"operator_recall"' "$_amb4e" && grep -q '"condition":"AUTH_DEAD"' "$_amb4e"; then
    pass "operator-recall emits AUTH_DEAD condition on repeated auth_token_stale"
else
    fail "operator-recall did not emit AUTH_DEAD on repeated auth_token_stale"
fi

# ── Test 5: operator-recall AUTH_DEAD fires on repeated oauth_token_refresh_failed ──

_amb5="$SANDBOX/ambient-recall-fail.jsonl"
for i in 1 2 3; do
    printf '{"ts":"%s","kind":"oauth_token_refresh_failed","reason":"keychain_miss"}\n' \
        "$_ts" >> "$_amb5"
done

_rc=0
CHUMP_AMBIENT_LOG="$_amb5" \
REPO_ROOT="$REPO_ROOT" \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
CHUMP_OAUTH_FAILURE_RECALL_THRESHOLD=3 \
CHUMP_AUTH_STORM_RECALL_THRESHOLD=999 \
CHUMP_AUTH_STALE_RECALL_THRESHOLD=999 \
"$REPO_ROOT/scripts/dispatch/operator-recall.sh" --check-only 2>/dev/null || _rc=$?

if (( _rc != 0 )); then
    pass "operator-recall --check-only exits 1 on repeated oauth_token_refresh_failed"
else
    fail "operator-recall --check-only should exit 1 on repeated oauth_token_refresh_failed but exited 0"
fi

# ── Test 6: original fleet_auth_storm+worker_exit path is unaffected ───────

_amb6="$SANDBOX/ambient-recall-storm.jsonl"
for i in 1 2 3 4 5; do
    printf '{"ts":"%s","kind":"fleet_auth_storm","action":"worker_exit","session":"%d"}\n' \
        "$_ts" "$i" >> "$_amb6"
done

_rc=0
CHUMP_AMBIENT_LOG="$_amb6" \
REPO_ROOT="$REPO_ROOT" \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
CHUMP_AUTH_STORM_RECALL_THRESHOLD=5 \
"$REPO_ROOT/scripts/dispatch/operator-recall.sh" --check-only 2>/dev/null || _rc=$?

if (( _rc != 0 )); then
    pass "original fleet_auth_storm+worker_exit AUTH_DEAD path still fires (AC5 regression guard)"
else
    fail "original fleet_auth_storm+worker_exit AUTH_DEAD path regressed"
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
