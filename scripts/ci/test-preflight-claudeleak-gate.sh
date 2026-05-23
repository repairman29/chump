#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }
ag "$PREFLIGHT" "test-no-claude-leak.sh" "preflight invokes no-claude-leak script"
ag "$PREFLIGHT" "CHUMP_PREFLIGHT_SKIP_CLAUDELEAK" "preflight honors CHUMP_PREFLIGHT_SKIP_CLAUDELEAK"
ag "$PREFLIGHT" '"preflight_claudeleak_bypassed"' "preflight emits preflight_claudeleak_bypassed"
ag "$RESERVED" "^preflight_claudeleak_bypassed" "reserved.txt allowlists preflight_claudeleak_bypassed"
ag "$PREFLIGHT" "INFRA-1793" "preflight has INFRA-1793 attribution"
[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1793: $failures"; exit 1; }
echo "OK INFRA-1793"
