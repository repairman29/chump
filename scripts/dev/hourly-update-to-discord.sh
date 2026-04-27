#!/usr/bin/env bash
# Send an hourly summary to Jeff via the notify tool (DM on Discord).
# Run from launchd every hour. Requires: CHUMP_READY_DM_USER_ID, DISCORD_TOKEN, model server (8000 or Ollama).
# Logs: logs/hourly-update.log
#
# FLEET-002 — Single fleet report gate:
#   Set CHUMP_FLEET_REPORT_ROLE=notify_only in .env to disable scheduled hourly updates
#   and let Mabel's report round be the single fleet report. Chump will still DM via the
#   notify tool for ad-hoc events (blocked, PR ready).
#   Alternative: run scripts/setup/retire-mac-hourly-fleet-report.sh to unload the launchd agent.
#
# NOTE (fleet report): Mabel's heartbeat `report` round is now the canonical fleet report —
# it covers Mac + Pixel health, Chump + Mabel tasks, and sends via notify. If Mabel's heartbeat
# is running, you can skip installing this script's launchd agent (hourly-update-to-discord.plist).
# Keep this script only if you want a Mac-only hourly backup for when the Pixel is offline.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/hourly-update.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# FLEET-002: skip scheduled hourly updates when Mabel owns the fleet report role.
if [[ "${CHUMP_FLEET_REPORT_ROLE:-}" == "notify_only" ]]; then
  log "SKIP: CHUMP_FLEET_REPORT_ROLE=notify_only — Mabel drives the fleet report (FLEET-002)"
  exit 0
fi

if [[ -z "${CHUMP_READY_DM_USER_ID:-}" ]] || [[ -z "${DISCORD_TOKEN:-}" ]]; then
  log "SKIP: CHUMP_READY_DM_USER_ID or DISCORD_TOKEN not set"
  exit 0
fi

# Use max_m4 env if 8000 is the configured backend
[[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && [[ -f "$ROOT/scripts/dev/env-max_m4.sh" ]] && source "$ROOT/scripts/dev/env-max_m4.sh"

# Daily provider summary: once per day (hour 20 UTC) try to include cascade usage if Chump Web is running
CASCADE_LINE=""
if [[ "$(date -u +%H)" == "20" ]]; then
  WEB_PORT="${CHUMP_WEB_PORT:-3000}"
  if command -v curl >/dev/null 2>&1; then
    CASCADE_JSON=$(curl -s -m 5 "http://127.0.0.1:${WEB_PORT}/api/cascade-status" 2>/dev/null || true)
    if [[ -n "$CASCADE_JSON" ]] && command -v jq >/dev/null 2>&1; then
      CASCADE_LINE=$(echo "$CASCADE_JSON" | jq -r '
        if .enabled and (.slots | length) > 0 then
          (if .provider_summary != null and .provider_summary != "" then .provider_summary else "Today cascade: " + ([.slots[] | "\(.name) \(.calls_today)/\(.rpd_limit)"] | join(", ")) end)
        else empty
        end
      ' 2>/dev/null)
    fi
  fi
fi

PROMPT="Hourly update for Jeff. In 3–5 short lines: (1) episode recent limit 5 — what you did recently; (2) task list — open/blocked; (3) anything that needs Jeff's attention or you're stuck on."
[[ -n "$CASCADE_LINE" ]] && PROMPT="$PROMPT (4) Include this in your summary: $CASCADE_LINE"
PROMPT="$PROMPT Then use the notify tool once with that summary. Be concise."

if [[ -x "$ROOT/target/release/chump" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 300 "$ROOT/target/release/chump" --chump "$PROMPT" >> "$LOG" 2>&1 || true
  else
    "$ROOT/target/release/chump" --chump "$PROMPT" >> "$LOG" 2>&1 || true
  fi
  log "Hourly update run done."
else
  log "SKIP: target/release/chump not found"
fi
exit 0
