#!/usr/bin/env bash
# scripts/ci/test-cli-help-regression.sh — INFRA-1789
#
# Regression guard for the `chump preflight --help` surface. INFRA-1246 added
# a broad "does every subcommand have --help" coverage check; this script is
# narrower and stricter — it diffs the exact `chump preflight --help` text
# against a committed golden file so a wording/flag change is caught even
# when coverage still passes (coverage only checks *presence*, not *content*).
#
# Run locally: bash scripts/ci/test-cli-help-regression.sh
# Update the golden file after an intentional --help change:
#   "$CHUMP" preflight --help > crates/chump-preflight/tests/help-golden.txt
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN="$REPO_ROOT/crates/chump-preflight/tests/help-golden.txt"

CHUMP="${CHUMP_BIN:-${REPO_ROOT}/target/debug/chump}"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="${CARGO_TARGET_DIR:-${REPO_ROOT}/target}/debug/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not found (run 'cargo build --bin chump')"
    exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
    echo "FAIL: golden file missing: $GOLDEN" >&2
    exit 1
fi

actual="$("$CHUMP" preflight --help 2>&1)"
expected="$(cat "$GOLDEN")"

if [[ "$actual" == "$expected" ]]; then
    echo "OK: chump preflight --help matches $GOLDEN"
    exit 0
fi

echo "FAIL: chump preflight --help drifted from $GOLDEN" >&2
diff <(echo "$expected") <(echo "$actual") >&2 || true
echo "If this drift is intentional, regenerate the golden file:" >&2
echo "  \"$CHUMP\" preflight --help > $GOLDEN" >&2
exit 1
