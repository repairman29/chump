#!/usr/bin/env bash
# scripts/ci/test-cli-help-regression.sh — INFRA-1789 (INFRA-1762 Tier C #3)
#
# Golden-file regression for `chump preflight --help`. INFRA-1246's broad
# canary step (test-runner-lane-broad-canary.sh "chump-help-regression")
# only checks that --help is *discoverable*, not that its *content* is
# stable — a stale flag description or a silently-dropped flag can ship
# without failing anything. This script closes that gap by diffing the
# live --help output against a committed golden file, locally, inside
# `chump preflight` itself (wired via discover_test_scripts).
#
# Usage:
#   scripts/ci/test-cli-help-regression.sh              # compare against golden
#   scripts/ci/test-cli-help-regression.sh --update      # rewrite the golden file
#
# Exit codes:
#   0  output matches golden file (or golden file was just written with --update)
#   1  output differs from golden file
#   0  chump binary not found (SKIP — mirrors test-cli-integration.sh's binary
#      discovery; a missing binary is a build-step concern, not this gate's)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN="$REPO_ROOT/crates/chump-preflight/tests/help-golden.txt"

CHUMP="${REPO_ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump')"
    exit 0
fi

actual="$("$CHUMP" preflight --help)"

if [[ "${1:-}" == "--update" ]]; then
    printf '%s\n' "$actual" > "$GOLDEN"
    echo "  wrote $GOLDEN"
    exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
    echo "  FAIL: golden file missing: $GOLDEN (run with --update to create it)"
    exit 1
fi

expected="$(cat "$GOLDEN")"

if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: chump preflight --help matches $GOLDEN"
    exit 0
fi

echo "  FAIL: chump preflight --help drifted from $GOLDEN"
diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
echo "  → if this drift is intentional, regenerate with:"
echo "    scripts/ci/test-cli-help-regression.sh --update"
exit 1
