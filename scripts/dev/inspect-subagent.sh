#!/usr/bin/env bash
# INFRA-399: Inspect an archived subagent transcript.
#
# Finds the archived output for a given agent ID and prints it with grep-friendly
# formatting: line numbers, tool call markers, error highlights.
#
# Usage:
#   inspect-subagent.sh <agent-id> [--grep PATTERN] [--errors] [--tools]
#
# agent-id:  Short ID (e.g. a5df003d2f1aa5097) or prefix — matches *.jsonl files
#            in ~/.claude/projects/*/notes/subagent-archive/
#
# Options:
#   --grep PATTERN   Filter output lines matching PATTERN
#   --errors         Show only lines containing "error", "Error", "FAIL", "fail"
#   --tools          Show only tool call / tool result lines
#
# Archive location: ~/.claude/projects/<project-slug>/notes/subagent-archive/
set -euo pipefail

AGENT_ID=""
GREP_PATTERN=""
FILTER_ERRORS=0
FILTER_TOOLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grep)   GREP_PATTERN="$2"; shift 2 ;;
    --errors) FILTER_ERRORS=1;   shift   ;;
    --tools)  FILTER_TOOLS=1;    shift   ;;
    -*)       echo "inspect-subagent.sh: unknown flag: $1" >&2; exit 1 ;;
    *)        AGENT_ID="$1";     shift   ;;
  esac
done

if [[ -z "$AGENT_ID" ]]; then
  echo "Usage: inspect-subagent.sh <agent-id> [--grep PATTERN] [--errors] [--tools]" >&2
  exit 1
fi

ARCHIVE_GLOB="${HOME}/.claude/projects/*/notes/subagent-archive/${AGENT_ID}*"

# shellcheck disable=SC2206
matches=( $ARCHIVE_GLOB )

if [[ ${#matches[@]} -eq 0 ]] || [[ ! -f "${matches[0]}" ]]; then
  echo "inspect-subagent.sh: no archived transcript found for agent '${AGENT_ID}'" >&2
  echo "  Searched: $ARCHIVE_GLOB" >&2
  echo "  Try: archive-subagent-transcripts.sh  (to archive recent sessions first)" >&2
  exit 1
fi

for match in "${matches[@]}"; do
  [[ -f "$match" ]] || continue
  echo "=== $match ==="

  # Decompress on-the-fly for .gz archives
  if [[ "$match" == *.gz ]]; then
    content="$(zcat "$match")"
  else
    content="$(cat "$match")"
  fi

  if [[ -n "$GREP_PATTERN" ]]; then
    echo "$content" | grep -n "$GREP_PATTERN" || true
  elif [[ "$FILTER_ERRORS" -eq 1 ]]; then
    echo "$content" | grep -n -iE 'error|FAIL|fail|panic|Error' || true
  elif [[ "$FILTER_TOOLS" -eq 1 ]]; then
    echo "$content" | grep -n -E '"type".*"tool|tool_use|tool_result' || true
  else
    echo "$content" | cat -n
  fi
done
