#!/usr/bin/env bash
# scripts/ci/test-infra-5083-materialize-creds-zero-touch.sh — INFRA-5083
#
# Regression test for chump-node-install.sh's materialize_creds() zero-touch
# credential handling (INFRA-3629 slice). Proves, without any network or
# interactive input:
#   1. $CHUMP_BOOTSTRAP_CREDS is read and materialized with no prompt.
#   2. --creds-file PATH is read and its contents used as the source.
#   3. Either path writes a complete ~/.chump/providers.env and returns 0.
#   4. When both are present, the env var takes precedence.
#   5. An existing providers.env is left untouched (idempotent, no clobber).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-infra-5083-materialize-creds-zero-touch.sh (INFRA-5083) ==="

# Source the installer without running main (BASH_SOURCE guard at EOF).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-creds-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state-unused"
mkdir -p "$CHUMP_NODE_DIR"
set --
# shellcheck disable=SC1090
. "$INSTALLER"

# ── 1. $CHUMP_BOOTSTRAP_CREDS alone: no prompt, writes complete file, exit 0 ──
STATE_DIR="$TMP/state1"; CREDS="$STATE_DIR/providers.env"; CREDS_FILE=""; DRY=0
CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-env\nGH_TOKEN=gh-env\n')"
export CHUMP_BOOTSTRAP_CREDS
materialize_creds </dev/null
rc=$?
[ "$rc" = 0 ] && pass "materialize_creds() from env var exits 0" || fail "materialize_creds() from env var exit=$rc"
[ -f "$CREDS" ] && pass "env-var path writes providers.env" || fail "env-var path did not write $CREDS"
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=tok-env$' "$CREDS" 2>/dev/null \
  && grep -q '^GH_TOKEN=gh-env$' "$CREDS" 2>/dev/null \
  && pass "env-var path: providers.env contains both required keys" \
  || fail "env-var path: providers.env missing expected keys"
unset CHUMP_BOOTSTRAP_CREDS

# ── 2. --creds-file alone: file is read and used ──────────────────────────
STATE_DIR="$TMP/state2"; CREDS="$STATE_DIR/providers.env"; DRY=0
SRC_FILE="$TMP/src-creds.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-file\nGH_TOKEN=gh-file\n' > "$SRC_FILE"
CREDS_FILE="$SRC_FILE"
materialize_creds </dev/null
rc=$?
[ "$rc" = 0 ] && pass "materialize_creds() from --creds-file exits 0" || fail "materialize_creds() from --creds-file exit=$rc"
[ -f "$CREDS" ] && grep -q '^GH_TOKEN=gh-file$' "$CREDS" \
  && pass "--creds-file path: contents copied into providers.env" \
  || fail "--creds-file path: providers.env missing/incorrect"
CREDS_FILE=""

# ── 3. both present: env var takes precedence over --creds-file ──────────
STATE_DIR="$TMP/state3"; CREDS="$STATE_DIR/providers.env"; DRY=0
CREDS_FILE="$SRC_FILE"
CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-precedence\nGH_TOKEN=gh-precedence\n')"
export CHUMP_BOOTSTRAP_CREDS
materialize_creds </dev/null
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=tok-precedence$' "$CREDS" 2>/dev/null \
  && pass "env var wins over --creds-file when both are supplied" \
  || fail "precedence violated: expected env-var contents in $CREDS"
unset CHUMP_BOOTSTRAP_CREDS
CREDS_FILE=""

# ── 4. existing providers.env is left untouched (idempotent) ─────────────
STATE_DIR="$TMP/state4"; CREDS="$STATE_DIR/providers.env"; DRY=0
mkdir -p "$STATE_DIR"
printf 'PRE_EXISTING=1\n' > "$CREDS"
CHUMP_BOOTSTRAP_CREDS="ignored"
export CHUMP_BOOTSTRAP_CREDS
materialize_creds </dev/null
grep -q '^PRE_EXISTING=1$' "$CREDS" \
  && pass "existing providers.env left untouched" \
  || fail "existing providers.env was clobbered"
unset CHUMP_BOOTSTRAP_CREDS

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: all materialize_creds() zero-touch checks passed"
  exit 0
else
  echo "FAIL: $fails check(s) failed"
  exit 1
fi
