#!/usr/bin/env bash
# Smoke test for heartbeat-learn.sh: runs with 1m duration and 20s interval, then checks
# the log for preflight and at least one round. Requires TAVILY_API_KEY in .env and a
# model server on 8000 or 8001. Run from rust-agent: ./scripts/test-heartbeat-learn.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
LOG="$ROOT/logs/heartbeat-learn.log"

# Mark start of this test run in the log so we can tail only our run (no hyphens in date for sed)
MARKER="[heartbeat-test $(date -u +%Y%m%dT%H%M%SZ)]"
echo "$MARKER start" >> "$LOG"

HEARTBEAT_DURATION=1m HEARTBEAT_INTERVAL=20s ./scripts/heartbeat-learn.sh || EXIT=$?

# Capture log lines after our marker (use line number to avoid sed regex issues)
MARKER_LINE=$(grep -n "heartbeat-test" "$LOG" | tail -1 | cut -d: -f1)
LOG_SNAPSHOT=$(tail -n +"${MARKER_LINE:-1}" "$LOG")

if [[ -n "${EXIT:-}" ]] && [[ "$EXIT" -ne 0 ]]; then
  echo "heartbeat-learn.sh exited with $EXIT. Log snippet:" >&2
  echo "$LOG_SNAPSHOT" | tail -40 >&2
  exit "$EXIT"
fi

# Assert expected log content (script flow; round may exit non-zero if model is flaky)
if ! echo "$LOG_SNAPSHOT" | grep -q "Preflight:"; then
  echo "FAIL: log missing Preflight line. Log snippet:" >&2
  echo "$LOG_SNAPSHOT" | tail -30 >&2
  exit 1
fi
if ! echo "$LOG_SNAPSHOT" | grep -q "Heartbeat started:"; then
  echo "FAIL: log missing Heartbeat started. Log snippet:" >&2
  echo "$LOG_SNAPSHOT" | tail -30 >&2
  exit 1
fi
if ! echo "$LOG_SNAPSHOT" | grep -q "Round 1: starting"; then
  echo "FAIL: log missing Round 1: starting. Log snippet:" >&2
  echo "$LOG_SNAPSHOT" | tail -30 >&2
  exit 1
fi
if ! echo "$LOG_SNAPSHOT" | grep -qE "Heartbeat finished after|Heartbeat done"; then
  echo "FAIL: log missing Heartbeat finished/done. Log snippet:" >&2
  echo "$LOG_SNAPSHOT" | tail -30 >&2
  exit 1
fi
# Prefer at least one round ok for full pass; log if round failed (model flaky)
if echo "$LOG_SNAPSHOT" | grep -q "Round 1: ok"; then
  echo "OK: Chump heartbeat smoke test passed (preflight, round ok, completion)."
else
  echo "OK: Chump heartbeat smoke test passed (preflight, round ran, completion). Round 1 exited non-zero (model may be down or busy)."
fi
