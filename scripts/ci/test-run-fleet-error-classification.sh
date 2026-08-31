#!/usr/bin/env bash
# CREDIBLE-390 (CREDIBLE-130 slice): verifies run-fleet's INFRA-621 launch
# probe classifies Anthropic API error responses into discrete classes
# (auth-invalid / credit-exhausted / rate-limit / network) instead of a
# blanket "authentication failed". Regression guard for the 2026-06-08
# false-positive where "Credit balance is too low" (a valid key, empty
# account) was reported as an ANTHROPIC_API_KEY auth failure.
#
# Extracts the `classify_probe_error` function verbatim out of run-fleet.sh
# (rather than re-implementing the classification logic here) so this test
# actually exercises the shipped code, not a parallel copy of it.
#
# Run from repo root: bash scripts/ci/test-run-fleet-error-classification.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RF="$ROOT/scripts/dispatch/run-fleet.sh"
[[ -f "$RF" ]] || { echo "FAIL: run-fleet.sh not found at $RF"; exit 1; }

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Extract the classify_probe_error() function body from run-fleet.sh.
fn_src="$(awk '/^classify_probe_error\(\)/{p=1} p{print} p&&/^}$/{exit}' "$RF")"
[[ -n "$fn_src" ]] || { echo "FAIL: could not extract classify_probe_error() from $RF"; exit 1; }

eval "$fn_src"

check() {
    local desc="$1" input="$2" expected="$3"
    local got
    got="$(classify_probe_error "$input")"
    if [[ "$got" == "$expected" ]]; then
        pass "$desc (got=$got)"
    else
        fail "$desc (expected=$expected got=$got)"
    fi
}

echo ""
echo "── run-fleet error classification tests (CREDIBLE-390) ────────────"

# AC1 + AC2: credit-exhaustion must classify as credit-exhausted, not auth-invalid.
check "credit balance too low -> credit-exhausted" \
    'API error: {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}' \
    "credit-exhausted"
check "402 payment required -> credit-exhausted" \
    'HTTP 402 Payment Required: billing account has insufficient funds' \
    "credit-exhausted"
check "insufficient_quota -> credit-exhausted" \
    '{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}' \
    "credit-exhausted"

# AC1: rate-limit
check "429 rate limit -> rate-limit" \
    '{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}' \
    "rate-limit"
check "too many requests -> rate-limit" \
    'HTTP 429 Too Many Requests' \
    "rate-limit"

# AC1: network
check "connection refused -> network" \
    'curl: (7) Failed to connect to api.anthropic.com port 443: Connection refused' \
    "network"
check "timeout -> network" \
    'error: request timed out after 90000ms' \
    "network"
check "could not resolve host -> network" \
    'curl: (6) Could not resolve host: api.anthropic.com' \
    "network"

# AC1: auth-invalid (and AC2 negative check: must NOT be credit-exhausted)
check "401 unauthorized -> auth-invalid" \
    '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' \
    "auth-invalid"
check "expired oauth token -> auth-invalid" \
    'error: 401 Unauthorized - invalid or expired token' \
    "auth-invalid"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
