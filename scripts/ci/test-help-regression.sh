#!/usr/bin/env bash
# scripts/ci/test-help-regression.sh — INFRA-1789
#
# Regression gate for stale CLI help surfaces (INFRA-1762 Tier C #3,
# sibling of the test-chump-subcommand-help.sh INFRA-1238 gate). Compares
# `chump preflight --help` byte-for-byte against the committed golden file
# at crates/chump-preflight/tests/help-golden.txt. A help string drifting
# out of sync with the real flag/gate set (new flag undocumented, stale
# gate list) fails loudly here instead of surfacing as a confused operator
# reading outdated --help output.
#
# Updating the golden on an intentional help-text change:
#   chump preflight --help > crates/chump-preflight/tests/help-golden.txt

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GOLDEN="$REPO_ROOT/crates/chump-preflight/tests/help-golden.txt"

CHUMP="${CHUMP_BIN:-$(command -v chump 2>/dev/null || true)}"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not on PATH (set CHUMP_BIN); skipping help-regression gate"
    exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
    echo "FAIL: golden file missing at $GOLDEN"
    exit 1
fi

actual="$("$CHUMP" preflight --help 2>/dev/null)"
expected="$(cat "$GOLDEN")"

if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: 'chump preflight --help' output differs from $GOLDEN"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
    echo
    echo "If this change is intentional, regenerate the golden:"
    echo "    chump preflight --help > $GOLDEN"
    exit 1
fi

echo "PASS: chump preflight --help matches golden"
