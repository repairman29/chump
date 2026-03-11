#!/usr/bin/env bash
# Farmer Brown: Chump keeper. Diagnoses the stack (model, embed, worker, Discord), kills stale
# processes when something is listening but unhealthy, then runs keep-chump-online to bring things up.
#
# Usage:
#   ./scripts/farmer-brown.sh           # diagnose + fix once
#   FARMER_BROWN_DIAGNOSE_ONLY=1 ./scripts/farmer-brown.sh   # diagnose only, no fix
#   FARMER_BROWN_INTERVAL=120 ./scripts/farmer-brown.sh      # loop every 120s (diagnose + fix)
#
# Env (optional): same as keep-chump-online (CHUMP_KEEPALIVE_EMBED, CHUMP_KEEPALIVE_DISCORD,
#   CHUMP_KEEPALIVE_WORKER, WARM_PORT_2, CHUMP_HOME, .env). Plus:
#   FARMER_BROWN_DIAGNOSE_ONLY=1   Only print/log diagnosis; do not fix or start services.
#   FARMER_BROWN_INTERVAL=N        Run in a loop every N seconds (diagnose + fix each time).
#   CHUMP_HEALTH_PORT              If set, Farmer Brown will also show Chump health JSON when diagnosing.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

LOG="$ROOT/logs/farmer-brown.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }
log_only() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

# --- Health checks (same contract as keep-chump-online) ---
port_ok() {
  local port=$1
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null)" == "200" ]]
}

embed_ok() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${CHUMP_EMBED_PORT:-18765}/" 2>/dev/null | grep -q '200\|404\|405'
}

chump_discord_running() {
  pgrep -f "rust-agent.*--discord" >/dev/null 2>&1
}

# PIDs listening on a port (macOS/BSD lsof).
pids_on_port() {
  local port=$1
  lsof -ti ":$port" 2>/dev/null || true
}

# Diagnose one component; set global LAST_DIAG (status string) and return 0=healthy, 1=unhealthy.
diagnose_model() {
  local port=${1:-8000}
  LAST_DIAG=""
  if port_ok "$port"; then
    LAST_DIAG="up"
    return 0
  fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || echo "000")
  if [[ -n "$(pids_on_port "$port")" ]]; then
    LAST_DIAG="down (port in use, got HTTP $code — stale?)"
  else
    LAST_DIAG="down (nothing on port $port)"
  fi
  return 1
}

diagnose_embed() {
  LAST_DIAG=""
  if embed_ok; then
    LAST_DIAG="up"
    return 0
  fi
  if [[ -n "$(pids_on_port "${CHUMP_EMBED_PORT:-18765}")" ]]; then
    LAST_DIAG="down (port in use but not responding)"
  else
    LAST_DIAG="down (not running)"
  fi
  return 1
}

diagnose_discord() {
  LAST_DIAG=""
  if [[ -f "$ROOT/logs/pause" ]] || [[ "${CHUMP_PAUSED:-0}" == "1" ]]; then
    LAST_DIAG="paused (logs/pause or CHUMP_PAUSED=1)"
    return 0
  fi
  if [[ -z "${DISCORD_TOKEN:-}" ]]; then
    LAST_DIAG="skipped (no DISCORD_TOKEN)"
    return 0
  fi
  if chump_discord_running; then
    LAST_DIAG="running"
    return 0
  fi
  LAST_DIAG="not running"
  return 1
}

# Kill processes on a port (use when health check fails but port is in use).
kill_stale_port() {
  local port=$1
  local name=${2:-"port $port"}
  local pids
  pids=$(pids_on_port "$port")
  if [[ -z "$pids" ]]; then return 0; fi
  log "Killing stale $name (PIDs: $pids)"
  kill $pids 2>/dev/null || true
  sleep 2
  # Force kill if still present
  pids=$(pids_on_port "$port")
  if [[ -n "$pids" ]]; then
    log_only "Force-killing $name (PIDs: $pids)"
    kill -9 $pids 2>/dev/null || true
  fi
}

run_diagnose() {
  log "=== Farmer Brown diagnosis ==="
  local need_fix=0

  # Model 8000
  if diagnose_model 8000; then
    log "  Model (8000): $LAST_DIAG"
  else
    log "  Model (8000): $LAST_DIAG"
    need_fix=1
  fi

  # Worker 8001 (optional)
  if [[ "${CHUMP_KEEPALIVE_WORKER:-0}" == "1" ]] || [[ -n "${WARM_PORT_2:-}" ]]; then
    local wport="${WARM_PORT_2:-8001}"
    if diagnose_model "$wport"; then
      log "  Worker ($wport): $LAST_DIAG"
    else
      log "  Worker ($wport): $LAST_DIAG"
      need_fix=1
    fi
  else
    log "  Worker: skipped (CHUMP_KEEPALIVE_WORKER/WARM_PORT_2 not set)"
  fi

  # Embed
  if [[ "${CHUMP_KEEPALIVE_EMBED:-0}" == "1" ]]; then
    if diagnose_embed; then
      log "  Embed (${CHUMP_EMBED_PORT:-18765}): $LAST_DIAG"
    else
      log "  Embed (${CHUMP_EMBED_PORT:-18765}): $LAST_DIAG"
      need_fix=1
    fi
  else
    log "  Embed: skipped (CHUMP_KEEPALIVE_EMBED=0)"
  fi

  # Discord
  if diagnose_discord; then
    log "  Discord: $LAST_DIAG"
  else
    log "  Discord: $LAST_DIAG"
    if [[ "${CHUMP_KEEPALIVE_DISCORD:-1}" == "1" ]] && [[ -n "${DISCORD_TOKEN:-}" ]]; then
      need_fix=1
    fi
  fi

  # Optional: Chump health endpoint
  if [[ -n "${CHUMP_HEALTH_PORT:-}" ]]; then
    local health
    health=$(curl -s --max-time 2 "http://127.0.0.1:${CHUMP_HEALTH_PORT}/health" 2>/dev/null || true)
    if [[ -n "$health" ]]; then
      log_only "  Chump health: $health"
    fi
  fi

  log "=== End diagnosis (need_fix=$need_fix) ==="
  return $need_fix
}

run_fix() {
  # Kill stale processes: something listening but not healthy.
  if ! port_ok 8000; then
    [[ -n "$(pids_on_port 8000)" ]] && kill_stale_port 8000 "model (8000)"
  fi
  if [[ "${CHUMP_KEEPALIVE_WORKER:-0}" == "1" ]] || [[ -n "${WARM_PORT_2:-}" ]]; then
    local wport="${WARM_PORT_2:-8001}"
    if ! port_ok "$wport"; then
      [[ -n "$(pids_on_port "$wport")" ]] && kill_stale_port "$wport" "worker ($wport)"
    fi
  fi
  if [[ "${CHUMP_KEEPALIVE_EMBED:-0}" == "1" ]]; then
    if ! embed_ok; then
      [[ -n "$(pids_on_port "${CHUMP_EMBED_PORT:-18765}")" ]] && kill_stale_port "${CHUMP_EMBED_PORT:-18765}" "embed"
    fi
  fi

  # Bring everything up (reuse keep-chump-online).
  log "Running keep-chump-online to ensure services..."
  CHUMP_KEEPALIVE_INTERVAL= ./scripts/keep-chump-online.sh
}

# --- Main ---
INTERVAL="${FARMER_BROWN_INTERVAL:-}"
DO_FIX=true
[[ "${FARMER_BROWN_DIAGNOSE_ONLY:-0}" == "1" ]] && DO_FIX=false

if [[ -n "$INTERVAL" ]] && [[ "$INTERVAL" -gt 0 ]]; then
  log "Farmer Brown loop every ${INTERVAL}s (diagnose + fix)"
  while true; do
    run_diagnose || true
    $DO_FIX && run_fix
    sleep "$INTERVAL"
  done
fi

run_diagnose
if $DO_FIX; then
  run_fix
  log "Farmer Brown pass done."
else
  log "Diagnosis only (FARMER_BROWN_DIAGNOSE_ONLY=1); no fix applied."
fi
