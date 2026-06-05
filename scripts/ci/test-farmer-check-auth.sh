#!/usr/bin/env bash
# Regression test for farmer.sh check_auth (RESILIENT-113).
# Asserts the durable fix: validate operator's auth mode FIRST before paging
# AUTH_DEAD. Pre-fix, this function paged AUTH_DEAD ~1.1×/min for 17h+ on
# operators using api-key auth (274 false positives in 4h, 2026-06-05).
#
# This test is the "regression guard" required by docs/process/DURABLE_FIX_DOCTRINE.md.
# It runs in isolated tempdirs so it doesn't write to the live ambient stream.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FARMER="$REPO_ROOT/scripts/coord/farmer.sh"

[[ -x "$FARMER" ]] || { echo "[test] FAIL: farmer.sh not executable"; exit 1; }
[[ "$(bash -n "$FARMER" 2>&1)" == "" ]] || { echo "[test] FAIL: syntax error"; exit 1; }

WORK="$(mktemp -d /tmp/farmer-check-auth-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
AMBIENT="$WORK/ambient.jsonl"
touch "$AMBIENT"

# Build a faux "REPO_ROOT" with the .env we want
FAUX_REPO="$WORK/repo"
mkdir -p "$FAUX_REPO/.chump-locks"
touch "$FAUX_REPO/.chump-locks/ambient.jsonl"

# Helper: run just check_auth() with a controlled env and capture last farmer_auth_* event.
_run_check_auth() {
    local _env_vars="$1"
    rm -f "$FAUX_REPO/.chump-locks/ambient.jsonl"
    touch "$FAUX_REPO/.chump-locks/ambient.jsonl"
    env -i PATH=/usr/bin:/bin HOME=/tmp $_env_vars \
        CHUMP_REPO_ROOT="$FAUX_REPO" \
        CHUMP_AMBIENT_LOG="$FAUX_REPO/.chump-locks/ambient.jsonl" \
        bash -c "
            cd '$FAUX_REPO' 2>/dev/null
            source '$FARMER' 2>/dev/null
            check_auth >/dev/null 2>&1
        " 2>&1
    grep '"kind":"farmer_auth_' "$FAUX_REPO/.chump-locks/ambient.jsonl" 2>/dev/null | tail -1
}

# ── (a) api-key mode + ANTHROPIC_API_KEY in env → AUTH OK ────────────────────
out=$(_run_check_auth "CHUMP_AUTH_MODE=api-key ANTHROPIC_API_KEY=sk-ant-fake")
echo "$out" | grep -q '"kind":"farmer_auth_ok"' \
    || { echo "[test] FAIL (a) api-key+env: expected farmer_auth_ok, got: $out"; exit 1; }
echo "[test] (a) api-key + ANTHROPIC_API_KEY in env: OK"

# ── (b) auto mode + ANTHROPIC_API_KEY in env → AUTH OK ───────────────────────
out=$(_run_check_auth "CHUMP_AUTH_MODE=auto ANTHROPIC_API_KEY=sk-ant-fake")
echo "$out" | grep -q '"kind":"farmer_auth_ok".*"mode":"auto"' \
    || { echo "[test] FAIL (b) auto+env: expected farmer_auth_ok mode=auto, got: $out"; exit 1; }
echo "[test] (b) auto + ANTHROPIC_API_KEY in env: OK"

# ── (c) auto mode + ANTHROPIC_API_KEY in .env (not env) → AUTH OK ────────────
# Write .env with API key, leave shell env unset.
echo 'ANTHROPIC_API_KEY="sk-ant-from-dot-env"' > "$FAUX_REPO/.env"
out=$(_run_check_auth "")
echo "$out" | grep -q '"kind":"farmer_auth_ok"' \
    || { echo "[test] FAIL (c) auto+.env: expected farmer_auth_ok, got: $out"; exit 1; }
echo "[test] (c) auto + ANTHROPIC_API_KEY in .env (operator's actual situation): OK"
rm -f "$FAUX_REPO/.env"

# ── (d) api-key mode + NO key anywhere → STILL pages (genuine misconfig) ─────
out=$(_run_check_auth "CHUMP_AUTH_MODE=api-key")
echo "$out" | grep -q '"kind":"farmer_auth_dead".*"reason":"api_key_mode_no_key"' \
    || { echo "[test] FAIL (d) api-key+no-key: expected farmer_auth_dead, got: $out"; exit 1; }
echo "[test] (d) api-key mode with no key → still pages: OK"

# ── (e) oauth mode + stale token + no api_key → STILL pages (real halt) ──────
# Create a stale oauth-token.json.
mkdir -p "$WORK/home/.chump"
echo '{}' > "$WORK/home/.chump/oauth-token.json"
# Backdate it 10 hours.
touch -t "$(date -v-10H +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 hours ago' +%Y%m%d%H%M.%S)" \
    "$WORK/home/.chump/oauth-token.json"
out=$(env -i PATH=/usr/bin:/bin HOME="$WORK/home" CHUMP_AUTH_MODE=oauth OAUTH_MAX_AGE_S=3600 \
    CHUMP_REPO_ROOT="$FAUX_REPO" CHUMP_AMBIENT_LOG="$FAUX_REPO/.chump-locks/ambient.jsonl" \
    bash -c "
        cd '$FAUX_REPO' 2>/dev/null
        source '$FARMER' 2>/dev/null
        check_auth >/dev/null 2>&1
        grep 'farmer_auth' '$FAUX_REPO/.chump-locks/ambient.jsonl' | tail -1
    " 2>&1)
echo "$out" | grep -q '"kind":"farmer_auth_dead"' \
    || { echo "[test] FAIL (e) oauth-stale: expected farmer_auth_dead, got: $out"; exit 1; }
echo "[test] (e) oauth-mode + stale token + no fallback → still pages: OK"

echo "[test-farmer-check-auth] PASS"
