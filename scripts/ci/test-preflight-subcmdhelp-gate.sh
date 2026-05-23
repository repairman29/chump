#!/usr/bin/env bash
# scripts/ci/test-preflight-subcmdhelp-gate.sh — INFRA-1789
#
# Verifies src/preflight.rs registers the chump-subcommand-help gate per
# the INFRA-1731 pattern (event-registry mirror, shipped #2377). Static
# checks on the Rust source — runtime gate behavior is covered by the
# underlying scripts/ci/test-chump-subcommand-help.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

failures=0

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if ! grep -qE -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $desc"
        echo "       file: ${file#"$REPO_ROOT/"}"
        echo "       pattern: $pattern"
        failures=$((failures + 1))
    fi
}

assert_grep "$PREFLIGHT" \
    "test-chump-subcommand-help.sh" \
    "preflight.rs invokes test-chump-subcommand-help.sh as a Step"

assert_grep "$PREFLIGHT" \
    "CHUMP_PREFLIGHT_SKIP_SUBCMDHELP" \
    "preflight.rs honors CHUMP_PREFLIGHT_SKIP_SUBCMDHELP bypass"

assert_grep "$PREFLIGHT" \
    '"preflight_subcmdhelp_bypassed"' \
    "preflight.rs emits kind=preflight_subcmdhelp_bypassed on bypass"

assert_grep "$RESERVED" \
    "^preflight_subcmdhelp_bypassed" \
    "event-registry-reserved.txt allowlists preflight_subcmdhelp_bypassed"

assert_grep "$PREFLIGHT" \
    "INFRA-1789" \
    "preflight.rs has INFRA-1789 attribution comment"

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1789: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1789: chump preflight has chump-subcommand-help gate with bypass + audit emit"
