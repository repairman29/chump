#!/usr/bin/env bash
# INFRA-2043 — assert inbox-check-urgent.sh is wired as a PreToolUse hook (not PostToolUse).
#
# Why: PostToolUse stdout is suppressed by Claude Code, so a hook on that channel
# fires but never surfaces its <system-reminder> XML to the mid-session agent.
# Only PreToolUse stdout is injected as context for the next tool call. This test
# guards against a regression where inbox-check-urgent.sh accidentally returns to
# the PostToolUse bucket — a class of silent-A2A-failure that took multiple sessions
# to diagnose.
#
# See: docs/process/CLAUDE_GOTCHAS.md "Claude Code hook output channels".

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SETTINGS="$REPO_ROOT/.claude/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
  echo "[FAIL] .claude/settings.json not found at $SETTINGS" >&2
  exit 1
fi

pass=0
fail=0

assert() {
  local name="$1"
  local cond="$2"
  if [[ "$cond" == "true" ]]; then
    echo "[PASS] $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name" >&2
    fail=$((fail + 1))
  fi
}

# Helpers — jq one-liners returning literal "true"/"false".
in_pretool=$(jq -r '
  [.hooks.PreToolUse // []
   | .[]?.hooks // []
   | .[]?.command // ""]
  | map(select(test("inbox-check-urgent\\.sh")))
  | length > 0' "$SETTINGS")

in_posttool=$(jq -r '
  [.hooks.PostToolUse // []
   | .[]?.hooks // []
   | .[]?.command // ""]
  | map(select(test("inbox-check-urgent\\.sh")))
  | length > 0' "$SETTINGS")

poll_in_posttool=$(jq -r '
  [.hooks.PostToolUse // []
   | .[]?.hooks // []
   | .[]?.command // ""]
  | map(select(test("inbox-poll\\.sh")))
  | length > 0' "$SETTINGS")

assert "inbox-check-urgent.sh is registered under PreToolUse" "$in_pretool"
assert "inbox-check-urgent.sh is NOT under PostToolUse (would be silent)" "$([ "$in_posttool" = "false" ] && echo true || echo false)"
assert "inbox-poll.sh remains under PostToolUse (digest append, session-keyed)" "$poll_in_posttool"

# Also assert the script itself exists and is executable.
URGENT_SCRIPT="$REPO_ROOT/scripts/coord/inbox-check-urgent.sh"
if [[ -x "$URGENT_SCRIPT" ]]; then
  assert "scripts/coord/inbox-check-urgent.sh exists and is executable" "true"
else
  assert "scripts/coord/inbox-check-urgent.sh exists and is executable" "false"
fi

echo ""
echo "Passed: $pass  Failed: $fail"

if (( fail > 0 )); then
  exit 1
fi
