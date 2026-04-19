#!/usr/bin/env bash
# Test fixture: returns 5xx on first call, success on subsequent.
COUNTER_FILE="${FAKE_CLAUDE_COUNTER:-/tmp/fake-claude-counter}"
n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$COUNTER_FILE"
if [ "$n" -eq 1 ]; then
  echo "API Error: 500 Internal server error. SIMULATED" >&2
  exit 1
fi
echo "fake-claude success on attempt $n" >&2
exit 0
