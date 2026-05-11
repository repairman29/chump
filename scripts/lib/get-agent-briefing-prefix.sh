#!/usr/bin/env bash
# get-agent-briefing-prefix.sh — prints the path to the default Agent briefing prefix.
#
# Usage in a subagent prompt builder:
#   PREFIX_PATH="$(bash scripts/lib/get-agent-briefing-prefix.sh)"
#   PROMPT="$(cat "$PREFIX_PATH")
#
#   ---
#
#   $TASK_SPECIFIC_PROMPT"
#
# Override default with CHUMP_AGENT_DEFAULT_PREFIX=<path>.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEFAULT="$REPO_ROOT/docs/process/SUBAGENT_DEFAULT_BRIEFING.md"
echo "${CHUMP_AGENT_DEFAULT_PREFIX:-$DEFAULT}"
