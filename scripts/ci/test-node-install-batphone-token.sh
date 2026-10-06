#!/usr/bin/env bash
# RESILIENT-1513: a store-node install must provision CHUMP_BATPHONE_TOKEN
# on-node — minted locally, written into providers.env at mode 0600, and
# NEVER echoed to stdout/logs. Without this, chump-fleet-server's POST
# /api/gap (and /api/mission) fail CLOSED with 401, discoverable only by a
# human curling the endpoint by hand (verified on the canonical gap-store
# node 2026-10-02, hand-fixed; this is the permanent fix).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/setup/chump-node-install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-batphone-token.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_STATE_DIR"

set --
# shellcheck disable=SC1090
. "$INSTALLER"

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

DRY=0
log_output="$(ensure_batphone_token 2>&1)"

# AC: a token is minted and written into $CREDS.
if grep -qE '^CHUMP_BATPHONE_TOKEN=.+' "$CREDS" 2>/dev/null; then
  pass "CHUMP_BATPHONE_TOKEN minted + written to $CREDS"
else
  fail "CHUMP_BATPHONE_TOKEN not written to $CREDS"
fi

token_value="$(grep -E '^CHUMP_BATPHONE_TOKEN=' "$CREDS" | head -1 | cut -d= -f2-)"

# AC: never printed — the mint log must not contain the actual token value.
if [ -n "$token_value" ] && printf '%s' "$log_output" | grep -qF "$token_value"; then
  fail "minted token value was echoed in logs"
else
  pass "minted token value is not echoed in logs"
fi

# AC: reasonably random/long (hex, >= 32 chars) — not a placeholder constant.
case "$token_value" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    if [ "${#token_value}" -ge 32 ]; then
      pass "minted token looks like real random hex (len=${#token_value})"
    else
      fail "minted token is too short to be a real secret (len=${#token_value})"
    fi
    ;;
  *) fail "minted token is not hex-shaped: $token_value" ;;
esac

# AC: file permissions are 0600 (secret-safe).
perm="$(stat -c %a "$CREDS" 2>/dev/null || stat -f %Lp "$CREDS" 2>/dev/null)"
if [ "$perm" = "600" ]; then
  pass "providers.env is mode 600"
else
  fail "providers.env is mode $perm, expected 600"
fi

# AC: idempotent — a second call does not mint a new token or clobber an
# operator-supplied one.
second_log="$(ensure_batphone_token 2>&1)"
second_value="$(grep -E '^CHUMP_BATPHONE_TOKEN=' "$CREDS" | head -1 | cut -d= -f2-)"
if [ "$second_value" = "$token_value" ]; then
  pass "re-running ensure_batphone_token does not mint a new token (idempotent)"
else
  fail "re-running ensure_batphone_token overwrote the existing token"
fi
if printf '%s' "$second_log" | grep -qi "already present"; then
  pass "second run reports the token as already present"
else
  fail "second run did not short-circuit on an already-present token: $second_log"
fi

if [ "$failures" -eq 0 ]; then
  echo "PASS: CHUMP_BATPHONE_TOKEN provisioning contract holds"
  exit 0
fi
echo "FAIL: $failures assertion(s) failed" >&2
exit 1
