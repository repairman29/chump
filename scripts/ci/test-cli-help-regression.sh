#!/usr/bin/env bash
# scripts/ci/test-cli-help-regression.sh
# INFRA-1789: `chump preflight --help` regression check.
#
# Catches a stale CLI surface (INFRA-1246 class) by diffing the live
# `chump preflight --help` output against a committed golden file. A
# deliberate CLI change updates the golden file in the same PR; an
# accidental drift (flag renamed/removed, help text edited without intent)
# fails this check locally instead of surfacing only in CI.
#
# Run: ./scripts/ci/test-cli-help-regression.sh

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

if [[ ! -f "$GOLDEN" ]]; then
    echo "  FAIL: missing golden file $GOLDEN"
    exit 1
fi

actual="$("$CHUMP" preflight --help 2>&1)"
expected="$(cat "$GOLDEN")"

if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: chump preflight --help matches golden file"
    exit 0
fi

echo "  FAIL: chump preflight --help output drifted from $GOLDEN"
diff <(echo "$expected") <(echo "$actual") || true
echo "  If this drift is intentional, regenerate the golden file:"
echo "    $CHUMP preflight --help > $GOLDEN"
exit 1
