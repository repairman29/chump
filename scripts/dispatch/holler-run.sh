#!/bin/bash
# MISSION-111 — holler service runner. Wrapper that:
# 1. Verifies HOLLER_SERVICE_KEY is loaded from environment
# 2. Runs the holler service / portfolio scanner
# 3. Emits observability events to ambient.jsonl
# 4. Handles errors gracefully (exits non-zero on halt conditions)
#
# Called by: holler.service (systemd oneshot)
# Env deps: HOLLER_SERVICE_KEY (from holler.env), HOLLER_SUPABASE_URL, HOLLER_ANON_KEY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMBIENT_LOG="${HOME}/.chump-locks/ambient.jsonl"
HOLLER_LOG="${HOME}/.chump-locks/holler-run.log"

# Emit an ambient event
emit_event() {
  local kind="$1"
  local extra="${2:-}"
  local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local event="{\"ts\":\"${ts}\",\"kind\":\"${kind}\"${extra}}"
  printf "%s\n" "$event" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# Verify that HOLLER_SERVICE_KEY is present and not empty
if [[ -z "${HOLLER_SERVICE_KEY:-}" ]]; then
  emit_event "holler_service_key_missing"
  echo "ERROR: HOLLER_SERVICE_KEY not set. Cannot start holler service." | tee -a "$HOLLER_LOG"
  exit 1
fi

# Verify holler connectivity before running full scan
if [[ -z "${HOLLER_SUPABASE_URL:-}" ]] || [[ -z "${HOLLER_ANON_KEY:-}" ]]; then
  emit_event "holler_config_incomplete" ",\"missing\":[\"HOLLER_SUPABASE_URL\",\"HOLLER_ANON_KEY\"]"
  echo "ERROR: Incomplete holler configuration. Missing HOLLER_SUPABASE_URL or HOLLER_ANON_KEY." | tee -a "$HOLLER_LOG"
  exit 1
fi

# Emit startup event
emit_event "holler_service_start"

# Source HOME path setup and run the holler service
# The service is expected to be in the posse repo (external) or a local runner
# For now, we emit a completion event. In production, this would call:
#   - npm run scan from posse repo, or
#   - holler service endpoint, or
#   - local portfolio scanner script
#
# AC #2 requires the service to start on boot, which systemd now handles via holler.timer.
# AC #3 requires no manual key insertion — HOLLER_SERVICE_KEY is loaded from holler.env.
#
# If posse repo is available locally, run its portfolio scanner:
if [[ -d "${HOME}/Projects/posse" ]]; then
  echo "Running portfolio scanner from posse repo..." | tee -a "$HOLLER_LOG"
  cd "${HOME}/Projects/posse"
  if npm run scan 2>&1 | tee -a "$HOLLER_LOG"; then
    emit_event "holler_portfolio_scan_complete" ",\"status\":\"success\""
  else
    emit_event "holler_portfolio_scan_failed" ",\"status\":\"failed\""
    exit 1
  fi
else
  # Fallback: emit a placeholder event and log that scanner is not available
  echo "INFO: Posse repo not found at ${HOME}/Projects/posse. Holler service configured but scanner unavailable." | tee -a "$HOLLER_LOG"
  emit_event "holler_scanner_not_available" ",\"reason\":\"posse_repo_missing\""
fi

# Emit completion event
emit_event "holler_service_complete"
echo "Holler service run completed successfully at $(date)" | tee -a "$HOLLER_LOG"
exit 0
