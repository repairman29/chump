#!/usr/bin/env bash
# test-operator-ping-anti-pattern.sh — INFRA-2209
#
# Audit surface: scan recent session transcripts for operator-ping question
# patterns ("should I", "would you like me to", "do you want me to",
# "what should", etc.). Emits a count + list of matches.
#
# This is NOT a CI gate (exit 0 always). It is an audit tool that surfaces
# the anti-pattern frequency. Wire it into periodic fleet health checks or
# run manually to see how often agents are bouncing decisions to the operator
# instead of using the NATS A2A consensus protocol (AGENTS.md §Decision
# protocol — consensus over operator-pinging, INFRA-2209).
#
# Usage:
#   scripts/ci/test-operator-ping-anti-pattern.sh [--window N] [--json] [--emit-ambient]
#
#   --window N        Number of most-recent transcript lines to scan per file
#                     (default: 500; use 0 for all)
#   --json            Output findings as JSON array to stdout
#   --emit-ambient    Emit kind=operator_ping_anti_pattern to ambient.jsonl
#                     (default: only when matches found AND --emit-ambient passed)
#
# Output: one line per match — "<file>:<lineno>: <matched text>"
# Exit:   always 0 (audit surface, not a hard gate)
#
# See also:
#   AGENTS.md §Decision protocol — consensus over operator-pinging
#   docs/process/SUBAGENT_DISPATCH.md §Execution contract
#   INFRA-2147 — broadcast.sh --to glob expansion bug (workaround: send individually)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

WINDOW=500
JSON_OUTPUT=0
EMIT_AMBIENT=0

for arg in "$@"; do
  case "$arg" in
    --window=*)     WINDOW="${arg#--window=}" ;;
    --window)       shift; WINDOW="$1" ;;
    --json)         JSON_OUTPUT=1 ;;
    --emit-ambient) EMIT_AMBIENT=1 ;;
  esac
done

# ── Transcript discovery ───────────────────────────────────────────────────────
# Look for session transcript files in common Claude Code locations.
# We scan: ~/.claude/projects/*/session*.jsonl,
#          ~/.chump/transcripts/,
#          .chump-plans/**/*.log
# Fall back gracefully if none found.

_find_transcripts() {
  local found=0

  # Claude Code project transcripts
  if [[ -d "$HOME/.claude/projects" ]]; then
    while IFS= read -r -d '' f; do
      echo "$f"
      found=1
    done < <(find "$HOME/.claude/projects" -maxdepth 3 \
      -name "*.jsonl" -newer "$REPO_ROOT/.chump-locks/ambient.jsonl" \
      -print0 2>/dev/null) || true
  fi

  # Chump-specific transcript dir
  if [[ -d "$HOME/.chump/transcripts" ]]; then
    while IFS= read -r -d '' f; do
      echo "$f"
      found=1
    done < <(find "$HOME/.chump/transcripts" -maxdepth 2 \
      -name "*.jsonl" -o -name "*.log" -print0 2>/dev/null) || true
  fi

  # .chump-plans logs
  if [[ -d "$REPO_ROOT/.chump-plans" ]]; then
    while IFS= read -r -d '' f; do
      echo "$f"
      found=1
    done < <(find "$REPO_ROOT/.chump-plans" -maxdepth 3 \
      -name "*.log" -print0 2>/dev/null) || true
  fi

  if [[ $found -eq 0 ]]; then
    # Nothing found — scan git log messages as a proxy (assistant message lines)
    git -C "$REPO_ROOT" log --oneline --since='7 days ago' --format='%s %b' 2>/dev/null \
      | head -200 > /tmp/chump-ping-gitlog-proxy.txt || true
    if [[ -s /tmp/chump-ping-gitlog-proxy.txt ]]; then
      echo "/tmp/chump-ping-gitlog-proxy.txt"
    fi
  fi
}

# ── Pattern definitions ────────────────────────────────────────────────────────
# Patterns that indicate an agent is asking the operator a question rather than
# making a call and broadcasting via consensus.
PATTERNS=(
  "should I"
  "Should I"
  "would you like me to"
  "Would you like me to"
  "do you want me to"
  "Do you want me to"
  "what should"
  "What should"
  "shall I"
  "Shall I"
  "is it okay if I"
  "Is it okay if I"
  "can I proceed"
  "Can I proceed"
  "do you want me"
  "Do you want me"
  "should we"
  "Should we"
  "what would you like"
  "What would you like"
)

# ── Scan ───────────────────────────────────────────────────────────────────────
declare -a MATCHES=()
declare -a MATCH_FILES=()
declare -a MATCH_LINES=()
declare -a MATCH_TEXTS=()

total_matches=0

while IFS= read -r transcript; do
  [[ -f "$transcript" ]] || continue

  # Apply window: last N lines, or all if WINDOW=0
  if [[ "$WINDOW" -gt 0 ]]; then
    content=$(tail -n "$WINDOW" "$transcript" 2>/dev/null) || continue
  else
    content=$(cat "$transcript" 2>/dev/null) || continue
  fi

  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    for pat in "${PATTERNS[@]}"; do
      if echo "$line" | grep -qF "$pat" 2>/dev/null; then
        # Skip lines inside code fences or that are clearly tool-call JSON
        # (heuristic: skip lines that start with { or contain "kind": or are backtick lines)
        first_char="${line:0:1}"
        if [[ "$first_char" == "{" ]] || echo "$line" | grep -qE '"kind"\s*:'; then
          continue
        fi
        if echo "$line" | grep -qE '^\s*```'; then
          continue
        fi

        MATCHES+=("${transcript}:${lineno}: ${line:0:120}")
        MATCH_FILES+=("$transcript")
        MATCH_LINES+=("$lineno")
        MATCH_TEXTS+=("${line:0:120}")
        total_matches=$((total_matches + 1))
        break  # one pattern match per line is enough
      fi
    done
  done <<< "$content"
done < <(_find_transcripts)

# ── Output ─────────────────────────────────────────────────────────────────────
if [[ $JSON_OUTPUT -eq 1 ]]; then
  printf '{"operator_ping_count":%d,"matches":[' "$total_matches"
  first=1
  for i in "${!MATCHES[@]}"; do
    [[ $first -eq 0 ]] && printf ','
    printf '{"file":"%s","line":%s,"text":"%s"}' \
      "${MATCH_FILES[$i]}" \
      "${MATCH_LINES[$i]}" \
      "$(echo "${MATCH_TEXTS[$i]}" | sed 's/"/\\"/g')"
    first=0
  done
  printf ']}\n'
else
  if [[ $total_matches -eq 0 ]]; then
    echo "operator-ping-anti-pattern: 0 matches in scanned transcripts (good)"
  else
    echo "operator-ping-anti-pattern: ${total_matches} match(es) found"
    echo "  Doctrine: use NATS A2A consensus (AGENTS.md §Decision protocol), not operator pings."
    echo ""
    for m in "${MATCHES[@]}"; do
      echo "  $m"
    done
  fi
fi

# ── Ambient emit ───────────────────────────────────────────────────────────────
if [[ $EMIT_AMBIENT -eq 1 ]] && [[ $total_matches -gt 0 ]]; then
  printf '{"ts":"%s","kind":"operator_ping_anti_pattern","count":%d,"note":"use consensus protocol per INFRA-2209"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$total_matches" \
    >> "$AMBIENT" 2>/dev/null || true
fi

# Always exit 0 — this is an audit surface, not a hard gate.
exit 0
