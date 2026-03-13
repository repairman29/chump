#!/usr/bin/env bash
# Send an hourly summary to Jeff via the notify tool (DM on Discord).
# Run from launchd every hour. Requires: CHUMP_READY_DM_USER_ID, DISCORD_TOKEN, model server (8000 or Ollama).
# Logs: logs/hourly-update.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/hourly-update.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

if [[ -z "${CHUMP_READY_DM_USER_ID:-}" ]] || [[ -z "${DISCORD_TOKEN:-}" ]]; then
  log "SKIP: CHUMP_READY_DM_USER_ID or DISCORD_TOKEN not set"
  exit 0
fi

# Use max_m4 env if 8000 is the configured backend
[[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && [[ -f "$ROOT/scripts/env-max_m4.sh" ]] && source "$ROOT/scripts/env-max_m4.sh"

PROMPT="Hourly update for Jeff. In 3–5 short lines: (1) episode recent limit 5 — what you did recently; (2) task list — open/blocked; (3) anything that needs Jeff's attention or you're stuck on. Then use the notify tool once with that summary. Be concise."

if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 300 "$ROOT/target/release/rust-agent" --chump "$PROMPT" >> "$LOG" 2>&1 || true
  else
    "$ROOT/target/release/rust-agent" --chump "$PROMPT" >> "$LOG" 2>&1 || true
  fi
  log "Hourly update run done."
else
  log "SKIP: target/release/rust-agent not found"
fi
exit 0
