#!/usr/bin/env bash
# scripts/ci/test-preflight-prscope-gate.sh — INFRA-1792
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }
ag "$PREFLIGHT" "check-pr-scope.sh" "preflight invokes check-pr-scope.sh"
ag "$PREFLIGHT" "CHUMP_PREFLIGHT_SKIP_PRSCOPE" "preflight honors CHUMP_PREFLIGHT_SKIP_PRSCOPE"
ag "$PREFLIGHT" '"preflight_prscope_bypassed"' "preflight emits preflight_prscope_bypassed"
ag "$RESERVED" "^preflight_prscope_bypassed" "reserved.txt allowlists preflight_prscope_bypassed"
ag "$PREFLIGHT" "INFRA-1792" "preflight has INFRA-1792 attribution"
[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1792: $failures"; exit 1; }
echo "OK INFRA-1792"
