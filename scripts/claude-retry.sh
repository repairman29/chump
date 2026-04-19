#!/usr/bin/env bash
# claude-retry.sh — wraps `claude` with retry on transient Anthropic API 5xx.
#
# Filed gap: INFRA-CHUMP-API-RETRY (P1).
# Motivating incident: docs/eval/AUTONOMY-TEST-2026-04-19.md — chump-orchestrator
# spawned `claude -p`, subprocess ran ~3 min of valid work, then Anthropic
# returned `API Error: 500 Internal server error` and the subprocess died with
# exit 1. The orchestrator handled it gracefully (KILLED outcome, clean
# summary) but no PR shipped because of one transient external 5xx. With this
# wrapper, the same dispatch self-recovers.
#
# Behavior:
#   - Pass through all args to `claude` verbatim.
#   - On exit != 0 with stderr containing 5xx markers, retry up to N times.
#   - On exit != 0 with non-5xx stderr (4xx, syntax, etc.), exit immediately.
#   - On exit == 0, exit immediately with success.
#   - All retries log to stderr with attempt number + reason.
#
# Configuration:
#   CHUMP_CLAUDE_RETRY_MAX (default 3)        — total attempts
#   CHUMP_CLAUDE_RETRY_BACKOFFS (default "30 60 120") — sleep seconds per retry
#   CHUMP_CLAUDE_RETRY_PATTERN (default below)         — extended regex matched
#                                                        against stderr to
#                                                        decide if error is
#                                                        retryable. Override
#                                                        for testing.
#
# Usage (drop-in for `claude`):
#   ./scripts/claude-retry.sh -p "do work" --bare
#
# Test:
#   CHUMP_CLAUDE_RETRY_PATTERN='SIMULATED_5XX' \
#     CHUMP_CLAUDE_BIN_OVERRIDE=./scripts/test-fixtures/fake-claude.sh \
#     ./scripts/claude-retry.sh ...

set -u

MAX_ATTEMPTS="${CHUMP_CLAUDE_RETRY_MAX:-3}"
read -r -a BACKOFFS <<<"${CHUMP_CLAUDE_RETRY_BACKOFFS:-30 60 120}"
RETRY_PATTERN="${CHUMP_CLAUDE_RETRY_PATTERN:-API Error: 5[0-9][0-9]|Internal server error|Bad Gateway|Service Unavailable|overloaded_error}"

# Allow tests to swap the actual binary
CLAUDE_BIN="${CHUMP_CLAUDE_BIN_OVERRIDE:-claude}"

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  STDERR_FILE=$(mktemp -t claude-retry.XXXXXX)
  trap 'rm -f "$STDERR_FILE"' EXIT

  # Run claude; capture stderr to file while also passing through to caller's
  # stderr so the orchestrator's stderr-tail thread (per AUTO-013 step 4) sees
  # diagnostic lines in real time.
  "$CLAUDE_BIN" "$@" 2> >(tee "$STDERR_FILE" >&2)
  EXIT=$?

  if [ "$EXIT" -eq 0 ]; then
    rm -f "$STDERR_FILE"
    exit 0
  fi

  # Decide whether to retry
  if grep -qE "$RETRY_PATTERN" "$STDERR_FILE"; then
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      sleep_for="${BACKOFFS[$((attempt-1))]:-${BACKOFFS[-1]}}"
      echo "[claude-retry] attempt $attempt/$MAX_ATTEMPTS exited $EXIT with retryable error; sleeping ${sleep_for}s before retry $((attempt+1))" >&2
      rm -f "$STDERR_FILE"
      sleep "$sleep_for"
      attempt=$((attempt+1))
      continue
    else
      echo "[claude-retry] attempt $attempt/$MAX_ATTEMPTS exited $EXIT with retryable error; retries exhausted, giving up" >&2
    fi
  else
    echo "[claude-retry] attempt $attempt exited $EXIT with non-retryable error; giving up" >&2
  fi

  rm -f "$STDERR_FILE"
  exit "$EXIT"
done

# Shouldn't reach here but defensive
exit 1
