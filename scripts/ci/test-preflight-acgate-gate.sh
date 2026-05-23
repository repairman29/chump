#!/usr/bin/env bash
# scripts/ci/test-preflight-acgate-gate.sh — INFRA-1791
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }
ag "$PREFLIGHT" "test-gap-preflight-ac-gate.sh" "preflight invokes the AC-gate script"
ag "$PREFLIGHT" "CHUMP_PREFLIGHT_SKIP_ACGATE" "preflight honors CHUMP_PREFLIGHT_SKIP_ACGATE"
ag "$PREFLIGHT" '"preflight_acgate_bypassed"' "preflight emits preflight_acgate_bypassed on bypass"
ag "$RESERVED" "^preflight_acgate_bypassed" "reserved.txt allowlists preflight_acgate_bypassed"
ag "$PREFLIGHT" "INFRA-1791" "preflight has INFRA-1791 attribution"
[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1791: $failures"; exit 1; }
echo "OK INFRA-1791: chump preflight has gap-preflight-ac-gate with bypass + audit emit"
