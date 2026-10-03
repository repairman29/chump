#!/usr/bin/env bash
# scripts/ci/test-preflight-help-regression.sh — INFRA-1789
#
# `chump preflight --help` is the only user-facing surface for the local CI
# mirror's flag set. INFRA-1246 proved that chump subcommand --help text
# drifts silently when a flag is added/renamed without updating the help
# string. This mirrors that discipline for the `preflight` subcommand
# specifically: diff live `--help` output against a committed golden file,
# and fail loud (not silent) on any drift.
#
# Golden file: crates/chump-preflight/tests/help-golden.txt
# To intentionally update the golden file after a help-text change:
#   "$CHUMP" preflight --help > crates/chump-preflight/tests/help-golden.txt
#
# Run: ./scripts/ci/test-preflight-help-regression.sh
# Registered via discover_test_scripts() in crates/chump-preflight/src/preflight.rs
# and as the "help-regression" step in scripts/setup/test-runner-lane-broad-canary.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN="$REPO_ROOT/crates/chump-preflight/tests/help-golden.txt"

CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump')"
    exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
    echo "  FAIL: golden file missing: $GOLDEN"
    exit 1
fi

ACTUAL="$("$CHUMP" preflight --help)"
EXPECTED="$(cat "$GOLDEN")"

if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo "  PASS: chump preflight --help matches $GOLDEN"
else
    echo "  FAIL: chump preflight --help drifted from $GOLDEN"
    echo "  --- diff (actual vs golden) ---"
    diff <(echo "$ACTUAL") <(echo "$EXPECTED") || true
    echo "  To accept this change: \"$CHUMP\" preflight --help > $GOLDEN"
    exit 1
fi
