#!/usr/bin/env bash
# scripts/ci/test-preflight-help-golden.sh — INFRA-1789 (ZERO-WASTE)
#
# Golden-file regression for `chump preflight --help`. A stale/drifted CLI
# surface (INFRA-1246 catches this class) should fail LOCALLY instead of
# only on CI — this diffs the live --help output against the committed
# golden file and exits non-zero on any mismatch, printing the diff so the
# fix (usually: update the golden file alongside the intentional flag/text
# change) is obvious.
#
# Run: ./scripts/ci/test-preflight-help-golden.sh
# Wired: crates/chump-preflight/src/preflight.rs discover_test_scripts() +
#        scripts/setup/test-runner-lane-broad-canary.sh "help-regression" step.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN="$REPO_ROOT/crates/chump-preflight/tests/help-golden.txt"

CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump')"
    exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
    echo "FAIL: golden file missing: $GOLDEN"
    exit 1
fi

ACTUAL="$("$CHUMP" preflight --help 2>&1)"

if ! diff -u "$GOLDEN" <(printf '%s\n' "$ACTUAL") > /tmp/preflight-help-golden.diff 2>&1; then
    echo "FAIL: 'chump preflight --help' output differs from $GOLDEN"
    echo "--- diff (golden vs actual) ---"
    cat /tmp/preflight-help-golden.diff
    echo "--------------------------------"
    echo "If this change to --help is intentional, update the golden file:"
    echo "  \"\$CHUMP\" preflight --help > $GOLDEN"
    rm -f /tmp/preflight-help-golden.diff
    exit 1
fi
rm -f /tmp/preflight-help-golden.diff

echo "PASS: chump preflight --help matches $GOLDEN"
exit 0
