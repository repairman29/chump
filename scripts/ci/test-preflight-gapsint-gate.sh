#!/usr/bin/env bash
# scripts/ci/test-preflight-gapsint-gate.sh — INFRA-1831
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }
ag "$PREFLIGHT" "check-gaps-integrity.py" "preflight invokes check-gaps-integrity.py"
ag "$PREFLIGHT" "CHUMP_PREFLIGHT_SKIP_GAPSINT" "preflight honors CHUMP_PREFLIGHT_SKIP_GAPSINT"
ag "$PREFLIGHT" '"preflight_gapsint_bypassed"' "preflight emits preflight_gapsint_bypassed"
ag "$RESERVED" "^preflight_gapsint_bypassed" "reserved.txt allowlists preflight_gapsint_bypassed"
ag "$PREFLIGHT" "INFRA-1831" "preflight has INFRA-1831 attribution"
[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1831: $failures"; exit 1; }
echo "OK INFRA-1831: chump preflight has gaps-integrity gate with bypass + audit emit"
