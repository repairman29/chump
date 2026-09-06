#!/usr/bin/env bash
# scripts/ci/test-node-install-creds-precedence.sh — INFRA-5083
#
# Regression test for chump-node-install.sh's zero-touch materialize_creds()
# (INFRA-3629 slice). Proves:
#   1. $CHUMP_BOOTSTRAP_CREDS alone materializes providers.env, no prompt.
#   2. --creds-file alone materializes providers.env, no prompt.
#   3. When BOTH are present, $CHUMP_BOOTSTRAP_CREDS wins (INFRA-5083 AC4).
#   4. materialize_creds returns 0 and leaves a complete file in each case.
#
# Network-free + deterministic: sources the installer (BASH_SOURCE guard
# prevents a real install run) and calls materialize_creds() directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-node-install-creds-precedence.sh (INFRA-5083) ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-creds-precedence-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── 1. $CHUMP_BOOTSTRAP_CREDS alone ─────────────────────────────────────────
export CHUMP_NODE_DIR="$TMP/node1"
export CHUMP_STATE_DIR="$TMP/state1"
mkdir -p "$CHUMP_NODE_DIR/bin"
export CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=envtok\nGH_TOKEN=envgh\n')"
set --
# shellcheck disable=SC1090
. "$INSTALLER"
materialize_creds
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$CREDS" ] && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=envtok$' "$CREDS" && grep -q '^GH_TOKEN=envgh$' "$CREDS"; then
  pass "env-only: materialize_creds() writes complete providers.env, exits 0"
else
  fail "env-only: expected complete providers.env from \$CHUMP_BOOTSTRAP_CREDS, got rc=$rc file=$([ -f "$CREDS" ] && cat "$CREDS")"
fi
unset CHUMP_BOOTSTRAP_CREDS

# ── 2. --creds-file alone ───────────────────────────────────────────────────
export CHUMP_NODE_DIR="$TMP/node2"
export CHUMP_STATE_DIR="$TMP/state2"
mkdir -p "$CHUMP_NODE_DIR/bin"
FILE_SRC="$TMP/providers-src.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=filetok\nGH_TOKEN=filegh\n' > "$FILE_SRC"
CREDS_FILE="$FILE_SRC"
set --
# shellcheck disable=SC1090
. "$INSTALLER"
CREDS_FILE="$FILE_SRC"
materialize_creds
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$CREDS" ] && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=filetok$' "$CREDS" && grep -q '^GH_TOKEN=filegh$' "$CREDS"; then
  pass "creds-file-only: materialize_creds() writes complete providers.env, exits 0"
else
  fail "creds-file-only: expected complete providers.env from --creds-file, got rc=$rc file=$([ -f "$CREDS" ] && cat "$CREDS")"
fi

# ── 3. both present -> $CHUMP_BOOTSTRAP_CREDS wins (INFRA-5083 AC4) ────────
export CHUMP_NODE_DIR="$TMP/node3"
export CHUMP_STATE_DIR="$TMP/state3"
mkdir -p "$CHUMP_NODE_DIR/bin"
export CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=envtok2\nGH_TOKEN=envgh2\n')"
set --
# shellcheck disable=SC1090
. "$INSTALLER"
CREDS_FILE="$FILE_SRC"
materialize_creds
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$CREDS" ] && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=envtok2$' "$CREDS" && ! grep -q 'filetok' "$CREDS"; then
  pass "both-present: \$CHUMP_BOOTSTRAP_CREDS takes precedence over --creds-file"
else
  fail "both-present: expected env var to win, got rc=$rc file=$([ -f "$CREDS" ] && cat "$CREDS")"
fi
unset CHUMP_BOOTSTRAP_CREDS

echo
if [ "$fails" -eq 0 ]; then echo "PASS: materialize_creds() zero-touch precedence holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
