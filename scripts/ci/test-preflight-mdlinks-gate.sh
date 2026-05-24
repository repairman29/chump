#!/usr/bin/env bash
# scripts/ci/test-preflight-mdlinks-gate.sh — INFRA-1790
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }
ag "$PREFLIGHT" "test-markdown-intra-doc-links.sh" "preflight invokes md-links script"
ag "$PREFLIGHT" "CHUMP_PREFLIGHT_SKIP_MDLINKS" "preflight honors CHUMP_PREFLIGHT_SKIP_MDLINKS"
ag "$PREFLIGHT" '"preflight_mdlinks_bypassed"' "preflight emits preflight_mdlinks_bypassed"
ag "$RESERVED" "^preflight_mdlinks_bypassed" "reserved.txt allowlists preflight_mdlinks_bypassed"
ag "$PREFLIGHT" "INFRA-1790" "preflight has INFRA-1790 attribution"
[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1790: $failures"; exit 1; }
echo "OK INFRA-1790"
