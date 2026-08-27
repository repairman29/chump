#!/usr/bin/env bash
# scripts/ci/test-help-regression.sh — INFRA-1789
#
# Golden-file regression gate: `chump gap rate --help` output must match
# crates/chump-preflight/tests/help-golden.txt byte-for-byte. Catches the
# "stale CLI surface" class (INFRA-1246 / INFRA-1762 Tier C #3) where a
# subcommand's usage string silently drifts (arg renamed/removed/added)
# without any test noticing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GOLDEN="$REPO_ROOT/crates/chump-preflight/tests/help-golden.txt"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; exit 0; }

CHUMP="${CHUMP_BIN:-$(command -v chump 2>/dev/null || true)}"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    skip "chump binary not on PATH (set CHUMP_BIN or 'cargo install --path .'); skipping help regression gate"
fi
if [[ ! -f "$GOLDEN" ]]; then
    fail "golden file missing: ${GOLDEN#"$REPO_ROOT"/}"
fi

export CHUMP_BINARY_STALENESS_CHECK=0

actual="$("$CHUMP" gap rate --help 2>&1)"
expected="$(cat "$GOLDEN")"

if [[ "$actual" != "$expected" ]]; then
    fail "chump gap rate --help drifted from golden file (${GOLDEN#"$REPO_ROOT"/}).
--- expected ---
$expected
--- actual ---
$actual
--- (regen: chump gap rate --help > ${GOLDEN#"$REPO_ROOT"/}) ---"
fi

ok "chump gap rate --help matches golden file"
