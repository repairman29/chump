#!/usr/bin/env bash
# CREDIBLE-137 regression guard.
#
# The fleet's #1 ship-blocker: workers' `claude -p` used a DEPLETED metered
# ANTHROPIC_API_KEY ("Credit balance is too low", api_error_status=400 → rc=1 →
# circuit-break) instead of the operator's valid flat-rate subscription OAuth
# token, because `claude -p` PREFERS ANTHROPIC_API_KEY when both it and
# CLAUDE_CODE_OAUTH_TOKEN are set (CLAUDE.md "precedence trap").
#
# The fix: worker.sh's refresh_oauth_token() must `unset ANTHROPIC_API_KEY`
# whenever a valid OAuth token is present, so claude uses the subscription.
# This test extracts that function and asserts the three auth branches.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$ROOT/scripts/dispatch/worker.sh"
[[ -f "$WORKER" ]] || { echo "FAIL: worker.sh not found at $WORKER"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# Extract just the refresh_oauth_token() function (start → first column-0 `}`).
fn="$(awk '/^refresh_oauth_token\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$WORKER")"
[[ -n "$fn" ]] || { echo "FAIL: could not extract refresh_oauth_token from worker.sh"; exit 1; }

# Static check: the success branch must unset ANTHROPIC_API_KEY (the actual fix).
if grep -Eq 'unset ANTHROPIC_API_KEY' <<<"$fn"; then
  ok "refresh_oauth_token contains 'unset ANTHROPIC_API_KEY'"
else
  fail "refresh_oauth_token does NOT unset ANTHROPIC_API_KEY — the precedence-trap fix is missing"
fi

# Behavioral check: define the function in this shell and exercise the branches.
log() { :; }   # worker.sh's logger, stubbed for the fallback branch
eval "$fn"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Case 1: valid OAuth token present → api-key dropped, oauth exported. ---
printf '{"token":"FAKE-OAT-TESTVALUE-NOT-A-SECRET"}' > "$tmp/oauth.json"
export CHUMP_OAUTH_TOKEN_FILE="$tmp/oauth.json"
export ANTHROPIC_API_KEY="DEPLETED-KEY-PLACEHOLDER-NOT-A-SECRET"
unset CLAUDE_CODE_OAUTH_TOKEN
refresh_oauth_token
[[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" == "FAKE-OAT-TESTVALUE-NOT-A-SECRET" ]] \
  && ok "case1: CLAUDE_CODE_OAUTH_TOKEN exported from token file" \
  || fail "case1: oauth token not exported (got '${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}')"
[[ -z "${ANTHROPIC_API_KEY:-}" ]] \
  && ok "case1: ANTHROPIC_API_KEY UNSET when oauth present (claude uses subscription)" \
  || fail "case1: ANTHROPIC_API_KEY still set ('${ANTHROPIC_API_KEY:-}') — precedence trap NOT fixed"

# --- Case 2: token file present but empty → fall back to ANTHROPIC_API_KEY. ---
printf '{}' > "$tmp/oauth.json"
export ANTHROPIC_API_KEY="FALLBACK-KEY-PLACEHOLDER-NOT-A-SECRET"
export CLAUDE_CODE_OAUTH_TOKEN="stale-should-be-cleared"
refresh_oauth_token
[[ "${ANTHROPIC_API_KEY:-}" == "FALLBACK-KEY-PLACEHOLDER-NOT-A-SECRET" ]] \
  && ok "case2: ANTHROPIC_API_KEY preserved as fallback when no oauth token" \
  || fail "case2: fallback api-key was dropped (got '${ANTHROPIC_API_KEY:-<unset>}')"
[[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
  && ok "case2: stale CLAUDE_CODE_OAUTH_TOKEN cleared on fallback" \
  || fail "case2: stale oauth token not cleared ('${CLAUDE_CODE_OAUTH_TOKEN:-}')"

# --- Case 3: no token file configured (api-key mode) → leave env untouched. ---
unset CHUMP_OAUTH_TOKEN_FILE
export ANTHROPIC_API_KEY="APIKEY-MODE-PLACEHOLDER-NOT-A-SECRET"
refresh_oauth_token
[[ "${ANTHROPIC_API_KEY:-}" == "APIKEY-MODE-PLACEHOLDER-NOT-A-SECRET" ]] \
  && ok "case3: api-key-mode env untouched when no token file configured" \
  || fail "case3: api-key clobbered in api-key mode (got '${ANTHROPIC_API_KEY:-<unset>}')"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-worker-oauth-unset.sh (all auth branches correct)"
  exit 0
else
  echo "FAIL: test-worker-oauth-unset.sh ($fails assertion(s) failed)"
  exit 1
fi
