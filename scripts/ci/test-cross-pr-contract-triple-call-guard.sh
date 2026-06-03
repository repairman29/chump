#!/usr/bin/env bash
# scripts/ci/test-cross-pr-contract-triple-call-guard.sh
#
# INFRA-2534: regression guard. The previous test-cross-pr-contract.sh
# invoked `chump contract-scan --in-flight` THREE times — once for stderr
# progress display, once captured-but-discarded, once captured-for-real.
# Each invocation walks 948 writers × all consumers. Tripling the scan
# wall-clock to ~20+ min caused operator-cancellation of 4 substrate PRs
# (#2981 / #2982 / #2983 / #2985) on 2026-06-03.
#
# This guard counts `chump contract-scan` invocations in the parent script's
# real-CI branch (NOT counting the self-test mock branch which legitimately
# uses CHUMP_BIN_OVERRIDE) and asserts the count is EXACTLY 1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARENT="$REPO_ROOT/scripts/ci/test-cross-pr-contract.sh"

if [[ ! -f "$PARENT" ]]; then
    echo "FAIL: $PARENT not found" >&2
    exit 1
fi

# Extract the real-CI branch (the `else` arm after the CHUMP_BIN_OVERRIDE guard).
# The branch starts after "if [[ -n \"${CHUMP_BIN_OVERRIDE:-}\" ]]; then" and
# ends at the matching `fi`. We extract up to the next top-level `if [[`.
real_ci_block="$(awk '
    /^if \[\[ -n "\${CHUMP_BIN_OVERRIDE:-}" \]\]; then$/ { in_block = 1; depth = 1; next }
    in_block && /^else$/ && depth == 1 { in_else = 1; next }
    in_else && /^if \[\[ \$SCAN_EXIT/ { in_block = 0; in_else = 0; exit }
    in_else { print }
' "$PARENT")"

if [[ -z "$real_ci_block" ]]; then
    echo "FAIL: could not extract real-CI branch from $PARENT" >&2
    echo "  (parent script structure may have changed — update the awk extractor)" >&2
    exit 1
fi

# Count occurrences of actual `chump contract-scan` invocations in the real-CI
# branch. Match $CHUMP_BIN reference followed by contract-scan — this excludes
# the echo/log line that mentions the command as a string.
# A real invocation looks like: `"$CHUMP_BIN" contract-scan --in-flight`
scan_count=$(printf '%s\n' "$real_ci_block" | grep -cE '"\$CHUMP_BIN"\s+contract-scan' || true)

echo "── INFRA-2534 triple-call guard ──"
echo "  real-CI branch lines: $(printf '%s\n' "$real_ci_block" | wc -l | tr -d ' ')"
echo "  chump contract-scan invocations: $scan_count"

if [[ "$scan_count" -eq 1 ]]; then
    echo "  PASS: single invocation"
    exit 0
elif [[ "$scan_count" -eq 0 ]]; then
    echo "  FAIL: zero invocations — script no longer calls contract-scan?" >&2
    exit 1
else
    echo "  FAIL: $scan_count invocations — INFRA-2534 regression. Real-CI branch must call contract-scan EXACTLY ONCE." >&2
    echo "  Each invocation walks 948 writers × all consumers — multiplying calls triples audit-step wall-clock." >&2
    exit 1
fi
