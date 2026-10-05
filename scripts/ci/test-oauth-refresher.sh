#!/usr/bin/env bash
# test-oauth-refresher.sh — INFRA-1865 smoke test for scripts/coord/oauth-token-refresh.sh
#
# Exercises the daemon end-to-end in a sandbox: a synthetic `security` stub
# stands in for the macOS keychain so the test runs on any host. Verifies:
#  1. stale token file gets a new mtime + new token blob on a real change
#  2. rotation-safe hash compare: identical token -> no rewrite, no ambient emit
#  3. validation gate: failed validation leaves the old file untouched + emits oauth_token_invalid
#  4. platform gate: non-Darwin host errors loudly (unless overridden for the sandbox)
#
# Run from repo root: bash scripts/ci/test-oauth-refresher.sh

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

# Fake `security` (macOS keychain CLI) — echoes a JSON blob shaped like the
# real `security find-generic-password -w` output for the Claude Code entry.
# Reads the token to embed from $SANDBOX/fake-token (so the test can flip it).
cat > "$SANDBOX/bin/security" <<'EOF'
#!/usr/bin/env bash
tok="$(cat "$SANDBOX_TOKEN_SRC" 2>/dev/null || echo "sk-ant-oat01-initial")"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$tok"
EOF
chmod +x "$SANDBOX/bin/security"

# Fake `claude` CLI stands in for the real validation call (AC4). Reads the
# desired verdict from $SANDBOX/fake-validation ("valid" prints PONG,
# anything else prints nothing so the `grep -q PONG` check fails).
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env bash
verdict="$(cat "$SANDBOX_VALIDATION_SRC" 2>/dev/null || echo valid)"
[[ "$verdict" == "valid" ]] && echo "PONG"
exit 0
EOF
chmod +x "$SANDBOX/bin/claude"
printf 'valid' > "$SANDBOX/fake-validation"

run_refresh() {
    PATH="$SANDBOX/bin:$PATH" \
    SANDBOX_TOKEN_SRC="$SANDBOX/fake-token" \
    SANDBOX_VALIDATION_SRC="$SANDBOX/fake-validation" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_OAUTH_TOKEN_FILE="$TOKEN_FILE" \
    CHUMP_OAUTH_PLATFORM_OVERRIDE="Darwin" \
    CHUMP_AUTH_MODE=oauth \
    ANTHROPIC_API_KEY= \
    bash "$REPO_ROOT/scripts/coord/oauth-token-refresh.sh" refresh-once
}

# ── Test 1: stale token file is rewritten with a fresh token + timestamp ───

printf '%s' "stale-token-16-days-old" > "$SANDBOX/fake-token"
printf '{"token":"OLD-STALE-TOKEN","written_at":"2026-07-28T00:00:00Z","source":"test"}\n' > "$TOKEN_FILE"
_before_mtime=$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE")
sleep 1
run_refresh >/dev/null 2>&1 || true

if grep -q "stale-token-16-days-old" "$TOKEN_FILE" 2>/dev/null; then
    pass "stale token file's blob is replaced with the freshly-extracted token"
else
    fail "token file blob was not updated on a real change"
fi

_after_mtime=$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE")
if [[ "$_after_mtime" -gt "$_before_mtime" ]]; then
    pass "token file mtime advances on a real change"
else
    fail "token file mtime did not advance"
fi

if grep -q '"kind":"oauth_token_refreshed"' "$AMBIENT" 2>/dev/null; then
    pass "kind=oauth_token_refreshed emitted on a real change"
else
    fail "kind=oauth_token_refreshed not emitted"
fi

# ── Test 2: rotation-safe hash compare — identical token is a no-op ───────

: > "$AMBIENT"
_before_mtime=$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE")
sleep 1
run_refresh >/dev/null 2>&1 || true
_after_mtime=$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE")

if [[ "$_after_mtime" == "$_before_mtime" ]]; then
    pass "unchanged token does not rewrite the file (rotation-safe hash compare)"
else
    fail "unchanged token rewrote the file anyway"
fi

if ! grep -q '"kind":"oauth_token_refreshed"' "$AMBIENT" 2>/dev/null; then
    pass "unchanged token does not emit kind=oauth_token_refreshed (no log spam)"
else
    fail "unchanged token still emitted oauth_token_refreshed"
fi

# ── Test 3: validation failure leaves the old file untouched ──────────────

: > "$AMBIENT"
printf '%s' "a-new-but-bad-token" > "$SANDBOX/fake-token"
printf 'invalid' > "$SANDBOX/fake-validation"
_prior_blob="$(cat "$TOKEN_FILE")"
run_refresh >/dev/null 2>&1 || true
printf 'valid' > "$SANDBOX/fake-validation"

if [[ "$(cat "$TOKEN_FILE")" == "$_prior_blob" ]]; then
    pass "failed validation leaves the existing token file untouched"
else
    fail "failed validation clobbered the existing token file"
fi

if grep -q '"kind":"oauth_token_invalid"' "$AMBIENT" 2>/dev/null; then
    pass "kind=oauth_token_invalid emitted on validation failure"
else
    fail "kind=oauth_token_invalid not emitted on validation failure"
fi

# ── Test 4: platform gate errors loudly on non-Darwin ──────────────────────

: > "$AMBIENT"
PATH="$SANDBOX/bin:$PATH" \
SANDBOX_TOKEN_SRC="$SANDBOX/fake-token" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_OAUTH_TOKEN_FILE="$TOKEN_FILE" \
CHUMP_OAUTH_PLATFORM_OVERRIDE="Linux" \
CHUMP_AUTH_MODE=oauth \
ANTHROPIC_API_KEY= \
bash "$REPO_ROOT/scripts/coord/oauth-token-refresh.sh" refresh-once >/dev/null 2>&1 || true

if grep -q '"kind":"oauth_refresh_unsupported_platform"' "$AMBIENT" 2>/dev/null; then
    pass "non-Darwin platform emits kind=oauth_refresh_unsupported_platform"
else
    fail "non-Darwin platform did not emit oauth_refresh_unsupported_platform"
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
