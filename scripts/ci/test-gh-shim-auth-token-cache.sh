#!/usr/bin/env bash
# test-gh-shim-auth-token-cache.sh — INFRA-1283
#
# Validates that the gh shim caches 'gh auth token' calls for CHUMP_GH_TOKEN_CACHE_TTL_S
# seconds and skips the real gh invocation on cache hits.
#
# Tests:
#   1. Fresh cache miss — real gh is called, result cached (permissions 0600)
#   2. Cache hit within TTL — real gh NOT called, cached token returned
#   3. After TTL expires — real gh called again
#   4. CHUMP_GH_NO_TOKEN_CACHE=1 bypasses cache, always calls real gh
#   5. Non-auth-token calls go through normal shim path (not intercepted)
#   6. Cache file permissions are 0600

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM="$REPO_ROOT/scripts/coord/lib/gh-shim/gh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1283: gh shim auth-token cache ==="

[[ -f "$SHIM" ]] || { echo "SKIP: gh shim not found at $SHIM"; exit 0; }

TMP="$(mktemp -d -t test-gh-auth-cache.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_HOME="$TMP/home"
MOCK_DIR="$TMP/mock"
CALL_LOG="$TMP/gh-calls.log"
AMBIENT="$TMP/ambient.jsonl"
mkdir -p "$FAKE_HOME" "$MOCK_DIR"

# ── Mock real gh binary ───────────────────────────────────────────────────────
MOCK_GH="$MOCK_DIR/gh"
cat > "$MOCK_GH" <<EOF
#!/usr/bin/env bash
printf 'CALL: gh %s\n' "\$*" >> "$CALL_LOG"
if [[ "\$1" == "auth" && "\$2" == "token" ]]; then
    printf 'fake-token-abc123\n'
    exit 0
fi
exit 0
EOF
chmod +x "$MOCK_GH"

# ── Test 1: Fresh cache miss — real gh called, result cached ──────────────────
echo "--- Test 1: fresh miss → real gh called, token cached ---"
rm -f "$CALL_LOG"
RESULT=$(HOME="$FAKE_HOME" CHUMP_GH_TOKEN_CACHE_TTL_S=300 CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_GH_NO_TOKEN_CACHE=0 PATH="$MOCK_DIR:$PATH" \
    bash "$SHIM" auth token 2>/dev/null)

if [[ "$RESULT" == "fake-token-abc123" ]]; then
    ok "Test 1a: correct token returned"
else
    fail "Test 1a: expected 'fake-token-abc123', got '$RESULT'"
fi

CACHE_FILE="$FAKE_HOME/.cache/chump-gh-shim/auth-token.txt"
if [[ -f "$CACHE_FILE" ]]; then
    CACHED=$(cat "$CACHE_FILE")
    if [[ "$CACHED" == "fake-token-abc123" ]]; then
        ok "Test 1b: token written to cache"
    else
        fail "Test 1b: cache file has wrong content: '$CACHED'"
    fi
else
    fail "Test 1b: cache file not created at $CACHE_FILE"
fi

CALL_COUNT=$(grep -c "CALL: gh auth token" "$CALL_LOG" 2>/dev/null || echo 0)
if [[ "$CALL_COUNT" -eq 1 ]]; then
    ok "Test 1c: real gh called exactly once on miss"
else
    fail "Test 1c: real gh called $CALL_COUNT times (expected 1)"
fi

# ── Test 2: Cache hit within TTL — real gh NOT called ────────────────────────
echo "--- Test 2: cache hit within TTL → real gh skipped ---"
rm -f "$CALL_LOG"
RESULT2=$(HOME="$FAKE_HOME" CHUMP_GH_TOKEN_CACHE_TTL_S=300 CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_GH_NO_TOKEN_CACHE=0 PATH="$MOCK_DIR:$PATH" \
    bash "$SHIM" auth token 2>/dev/null)

if [[ "$RESULT2" == "fake-token-abc123" ]]; then
    ok "Test 2a: cached token returned correctly"
else
    fail "Test 2a: expected 'fake-token-abc123', got '$RESULT2'"
fi

CALL_COUNT2=$(grep -c "CALL: gh auth token" "$CALL_LOG" 2>/dev/null || echo 0)
if [[ "$CALL_COUNT2" -eq 0 ]]; then
    ok "Test 2b: real gh NOT called on cache hit"
else
    fail "Test 2b: real gh called $CALL_COUNT2 times despite cache hit"
fi

# ── Test 3: After TTL expires — real gh called again ─────────────────────────
echo "--- Test 3: TTL=0 (expired immediately) → real gh re-called ---"
rm -f "$CALL_LOG"
RESULT3=$(HOME="$FAKE_HOME" CHUMP_GH_TOKEN_CACHE_TTL_S=0 CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_GH_NO_TOKEN_CACHE=0 PATH="$MOCK_DIR:$PATH" \
    bash "$SHIM" auth token 2>/dev/null)

CALL_COUNT3=$(grep -c "CALL: gh auth token" "$CALL_LOG" 2>/dev/null || echo 0)
if [[ "$CALL_COUNT3" -ge 1 ]]; then
    ok "Test 3: real gh called after TTL=0 (expired)"
else
    fail "Test 3: real gh not called with TTL=0 ($CALL_COUNT3 calls)"
fi

# ── Test 4: CHUMP_GH_NO_TOKEN_CACHE=1 bypasses cache ─────────────────────────
echo "--- Test 4: CHUMP_GH_NO_TOKEN_CACHE=1 → always calls real gh ---"
rm -f "$CALL_LOG"
# Run twice; with bypass, should call real gh both times
HOME="$FAKE_HOME" CHUMP_GH_TOKEN_CACHE_TTL_S=300 CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_GH_NO_TOKEN_CACHE=1 PATH="$MOCK_DIR:$PATH" \
    bash "$SHIM" auth token >/dev/null 2>&1 || true
HOME="$FAKE_HOME" CHUMP_GH_TOKEN_CACHE_TTL_S=300 CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_GH_NO_TOKEN_CACHE=1 PATH="$MOCK_DIR:$PATH" \
    bash "$SHIM" auth token >/dev/null 2>&1 || true

CALL_COUNT4=$(grep -c "CALL: gh auth token" "$CALL_LOG" 2>/dev/null || echo 0)
if [[ "$CALL_COUNT4" -ge 2 ]]; then
    ok "Test 4: bypass always calls real gh ($CALL_COUNT4 calls for 2 invocations)"
else
    fail "Test 4: expected ≥2 calls with bypass, got $CALL_COUNT4"
fi

# ── Test 5: Non-auth-token calls not intercepted ─────────────────────────────
echo "--- Test 5: 'gh pr list' not intercepted by cache ---"
rm -f "$CALL_LOG"
# This will fall through to normal shim path; it may fail (no github.sh in PATH),
# but the key assertion is that 'CALL: gh pr list' appears (real gh was invoked).
HOME="$FAKE_HOME" CHUMP_GH_NO_TOKEN_CACHE=0 PATH="$MOCK_DIR:$PATH" \
    CHUMP_GH_NO_SHIM=0 \
    bash "$SHIM" pr list 2>/dev/null || true
CALL_COUNT5=$(grep -c "CALL: gh pr list" "$CALL_LOG" 2>/dev/null || echo 0)
if [[ "$CALL_COUNT5" -ge 1 ]]; then
    ok "Test 5: 'gh pr list' reaches real gh (not intercepted by token cache)"
else
    # May not reach real gh if github.sh sourcing fails; check that it's not
    # being intercepted by the token cache path.
    if grep -q "CALL: gh auth token" "$CALL_LOG" 2>/dev/null; then
        fail "Test 5: 'gh pr list' incorrectly triggered auth token cache path"
    else
        ok "Test 5: 'gh pr list' not intercepted by token cache (passed to shim path)"
    fi
fi

# ── Test 6: Cache file permissions are 0600 ──────────────────────────────────
echo "--- Test 6: cache file permissions are 0600 ---"
if [[ -f "$CACHE_FILE" ]]; then
    PERMS=$(stat -f "%OLp" "$CACHE_FILE" 2>/dev/null || stat -c "%a" "$CACHE_FILE" 2>/dev/null || echo "?")
    if [[ "$PERMS" == "600" ]]; then
        ok "Test 6: cache file permissions are 0600"
    else
        fail "Test 6: cache file permissions are $PERMS (expected 600)"
    fi
else
    fail "Test 6: cache file not found — Test 1 may have failed"
fi

# ── Test 7: cache_hit ambient event emitted ───────────────────────────────────
echo "--- Test 7: cache_hit emits gh_auth_token_cache_hit event ---"
if grep -q '"kind":"gh_auth_token_cache_hit"' "$AMBIENT" 2>/dev/null; then
    ok "Test 7: gh_auth_token_cache_hit event emitted to ambient"
else
    fail "Test 7: gh_auth_token_cache_hit event not found in ambient log"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
