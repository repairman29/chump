#!/usr/bin/env bash
# test-no-anthropic-smoke.sh — CREDIBLE-046
#
# Proves chump's coordination layer works without ANY Anthropic credentials.
# This enforces the "chump-first" doctrine: Claude is one backend among many.
#
# What is tested (the coordination contract):
#   1. chump gap list  — reads state.db, no API call
#   2. chump gap reserve — writes state.db + YAML, no API call
#   3. chump gap ship  — flips status, mirrors YAML, no API call
#   4. No Anthropic credential is consumed at any point
#
# Worker spawn (Ollama/opencode) is explicitly NOT tested here — that is an
# integration concern. This test covers the coordination substrate that must
# work independently of any LLM backend.
#
# Usage in CI:
#   ANTHROPIC_API_KEY="" CLAUDE_CODE_OAUTH_TOKEN="" bash scripts/ci/test-no-anthropic-smoke.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Hard-unset Anthropic credentials — any test below that calls the Anthropic
# API will fail with a timeout or 401, which is exactly what we want to catch.
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_OAUTH_TOKEN
export ANTHROPIC_API_KEY=""
export CLAUDE_CODE_OAUTH_TOKEN=""

# Resolve chump binary
CHUMP_BIN="${CHUMP_BIN:-chump}"
command -v "$CHUMP_BIN" >/dev/null 2>&1 || fail "Cannot find chump binary at CHUMP_BIN=$CHUMP_BIN"

TMP="$(mktemp -d -t test-credible-046.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== CREDIBLE-046: no-Anthropic smoke test ==="
echo "CHUMP_BIN=$CHUMP_BIN"
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-(unset)}"
echo ""

# ── Test 1: chump gap list works without creds ──────────────────────────────
echo "--- Test 1: gap list ---"
# Use a fresh temp state.db so we don't depend on main repo state in CI
export CHUMP_STATE_DB="$TMP/state.db"
output=$("$CHUMP_BIN" gap list --status open 2>&1 || true)
# Should not error out, may print "state.db is empty" or a list
# INFRA-1900: anchor the grep to actual Anthropic-call failure markers, not
# gap-title substrings. Old pattern "Error.*anthropic\|401\|API key" tripped
# false-positive on gap titles like "INFRA-1893: HTTP 401 Bad credentials"
# or gaps referencing "API key" when auto-import populated the temp state.db
# from docs/gaps/ on empty-state.db path (INFRA-821) and dumped them.
# New pattern matches concrete failure phrases the Anthropic SDK actually
# emits when a real API call is attempted without creds.
if echo "$output" | grep -qE "ANTHROPIC_API_KEY (not set|missing|required)|anthropic\.com.*401|HTTP 401 .* api\.anthropic\.com|reqwest::Error.*api\.anthropic"; then
    fail "gap list made an Anthropic API call: $output"
fi
pass "gap list works without Anthropic creds"

# ── Test 2: chump gap reserve works without creds ──────────────────────────
echo "--- Test 2: gap reserve ---"
gap_id=$(FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve \
    --domain TEST \
    --title "TEST: CREDIBLE-046 no-anthropic smoke fixture" \
    --priority P3 2>&1 | grep '^TEST-' | tail -1)
[ -n "$gap_id" ] || fail "gap reserve failed or returned no gap ID"
yaml_path="$REPO_ROOT/docs/gaps/${gap_id}.yaml"
[ -f "$yaml_path" ] || fail "YAML file not created at $yaml_path"
grep -q "status: open" "$yaml_path" || fail "YAML status is not 'open'"
pass "gap reserve works without Anthropic creds (gap=$gap_id)"

# ── Test 3: chump gap show works without creds ─────────────────────────────
echo "--- Test 3: gap show ---"
show_out=$("$CHUMP_BIN" gap show "$gap_id" 2>&1)
echo "$show_out" | grep -q "id: $gap_id" || fail "gap show did not return expected ID"
if echo "$show_out" | grep -q "Error.*anthropic\|401\|API key"; then
    fail "gap show made an Anthropic API call"
fi
pass "gap show works without Anthropic creds"

# ── Test 4: chump gap ship works without creds ─────────────────────────────
echo "--- Test 4: gap ship ---"
CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
CHUMP_SHIP_NO_AUTOSTAGE=1 \
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
CHUMP_BYPASS_PROOF_OF_MERGE=1 \
"$CHUMP_BIN" gap ship "$gap_id" --update-yaml --closed-pr 9999 \
    || fail "gap ship failed"
grep -q "status: done" "$yaml_path" || fail "YAML status not 'done' after ship"
pass "gap ship works without Anthropic creds"

# ── Test 5: no Anthropic API calls in ambient log ──────────────────────────
echo "--- Test 5: no Anthropic API calls ---"
ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"
if [ -f "$ambient" ]; then
    # Check last 20 events — none should have provider=anthropic from this session
    recent_anthropic=$(tail -20 "$ambient" 2>/dev/null | \
        python3 -c "
import sys,json
count=0
for line in sys.stdin:
    try:
        e=json.loads(line.strip())
        if e.get('provider')=='anthropic' and 'TEST-' in str(e):
            count+=1
    except: pass
print(count)
" 2>/dev/null || echo "0")
    if [ "$recent_anthropic" -gt 0 ]; then
        fail "Detected $recent_anthropic Anthropic API call(s) for TEST gap — chump-first contract violated"
    fi
    pass "no Anthropic API calls emitted for coordination operations"
else
    pass "ambient log check skipped (not available in this environment)"
fi

# ── Cleanup: remove test fixture gap from docs/ ────────────────────────────
rm -f "$yaml_path"

echo ""
echo "All CREDIBLE-046 no-Anthropic smoke tests passed."
echo "chump's coordination layer is Anthropic-independent."
