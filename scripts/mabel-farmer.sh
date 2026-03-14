#!/usr/bin/env bash
# Mabel Farmer: Remote stack monitor running on the Pixel (Termux) over Tailscale.
# Replaces Farmer Brown, Sentinel, and Heartbeat Shepherd duties with an independent observer
# on a separate device. Diagnoses the Mac's Chump stack via SSH/HTTP over Tailscale, and
# optionally triggers fixes remotely.
#
# This script runs ON THE PIXEL. It SSHes into the Mac (Tailscale IP) to check services,
# read logs, and trigger repairs. Mabel also checks her own local llama-server health.
#
# Usage:
#   ./scripts/mabel-farmer.sh                          # diagnose + fix once
#   MABEL_FARMER_DIAGNOSE_ONLY=1 ./scripts/mabel-farmer.sh  # diagnose only
#   MABEL_FARMER_INTERVAL=120 ./scripts/mabel-farmer.sh     # loop every 120s
#
# Env (in ~/chump/.env on the Pixel):
#   MAC_TAILSCALE_IP          Tailscale IP of the Mac (required). e.g. 100.x.y.z
#   MAC_TAILSCALE_USER        SSH user on the Mac (default: same as local $USER).
#   MAC_SSH_PORT              SSH port on the Mac (default: 22).
#   MAC_CHUMP_HOME            Chump repo path on the Mac (default: ~/Projects/Chump).
#   MAC_OLLAMA_PORT           Ollama port on Mac (default: 11434).
#   MAC_MODEL_PORT            Model/API port on Mac (default: 8000).
#   MAC_EMBED_PORT            Embed server port on Mac (default: 18765).
#   MAC_HEALTH_PORT           Chump health endpoint port on Mac (optional).
#   MABEL_FARMER_DIAGNOSE_ONLY=1   Only diagnose; do not trigger remote fixes.
#   MABEL_FARMER_INTERVAL=N        Loop every N seconds.
#   MABEL_FARMER_FIX_CMD     Override remote fix command (default: farmer-brown.sh on Mac).
#   MABEL_FARMER_FIX_LOCAL=1  When Pixel model or bot is down, run local fix (start-companion.sh). Default: 1.
#   MABEL_CHECK_LOCAL=1       Also check local llama-server on the Pixel (default: 1).
#   MABEL_LOCAL_PORT          Local llama-server port on Pixel (default: 8000).
#   MABEL_DISCORD_NOTIFY=1    DM the configured user via Chump --notify on alert (requires DISCORD_TOKEN + CHUMP_READY_DM_USER_ID).
#   CHUMP_HOME                Chump home on the Pixel (default: script dir/..).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

LOG="$ROOT/logs/mabel-farmer.log"
mkdir -p "$ROOT/logs"

# --- Config ---
MAC_IP="${MAC_TAILSCALE_IP:-}"
MAC_USER="${MAC_TAILSCALE_USER:-$USER}"
MAC_SSH_PORT="${MAC_SSH_PORT:-22}"
MAC_HOME="${MAC_CHUMP_HOME:-~/Projects/Chump}"
MAC_OLLAMA_PORT="${MAC_OLLAMA_PORT:-11434}"
MAC_MODEL_PORT="${MAC_MODEL_PORT:-8000}"
MAC_EMBED_PORT="${MAC_EMBED_PORT:-18765}"
MAC_HEALTH_PORT="${MAC_HEALTH_PORT:-}"
LOCAL_PORT="${MABEL_LOCAL_PORT:-8000}"
CHECK_LOCAL="${MABEL_CHECK_LOCAL:-1}"
FIX_LOCAL="${MABEL_FARMER_FIX_LOCAL:-1}"
DO_FIX=true
[[ "${MABEL_FARMER_DIAGNOSE_ONLY:-0}" == "1" ]] && DO_FIX=false

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] MABEL-FARMER $*" | tee -a "$LOG"; }
log_only() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] MABEL-FARMER $*" >> "$LOG"; }

if [[ -z "$MAC_IP" ]]; then
  log "ERROR: MAC_TAILSCALE_IP not set. Cannot monitor Mac remotely."
  exit 1
fi

SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=5 -p $MAC_SSH_PORT ${MAC_USER}@${MAC_IP}"

# ─────────────────────────────────────────────────────────────
# Connectivity check: can we reach the Mac at all?
# ─────────────────────────────────────────────────────────────
check_tailscale_reachable() {
  if ping -c 1 -W 3 "$MAC_IP" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_ssh_reachable() {
  if $SSH_CMD "echo ok" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────
# Remote health checks (run on Pixel, probe Mac via HTTP/SSH)
# ─────────────────────────────────────────────────────────────

# Check a remote HTTP port from the Pixel (over Tailscale network).
remote_port_ok() {
  local port=$1
  local path="${2:-/v1/models}"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${MAC_IP}:${port}${path}" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

remote_ollama_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${MAC_IP}:${MAC_OLLAMA_PORT}/api/tags" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

remote_embed_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${MAC_IP}:${MAC_EMBED_PORT}/" 2>/dev/null || echo "000")
  [[ "$code" =~ ^(200|404|405)$ ]]
}

remote_discord_running() {
  $SSH_CMD "pgrep -f 'rust-agent.*--discord'" >/dev/null 2>&1 || $SSH_CMD "pgrep -f 'chump.*--discord'" >/dev/null 2>&1
}

remote_heartbeat_health() {
  # Returns recent heartbeat status from Mac logs
  $SSH_CMD "cd $MAC_HOME && tail -n 30 logs/heartbeat-learn.log 2>/dev/null" 2>/dev/null || echo "(unreachable)"
}

remote_farmer_log_tail() {
  $SSH_CMD "cd $MAC_HOME && tail -n 20 logs/farmer-brown.log 2>/dev/null" 2>/dev/null || echo "(unreachable)"
}

# ─────────────────────────────────────────────────────────────
# Local health check (Mabel's own llama-server on the Pixel)
# ─────────────────────────────────────────────────────────────
local_model_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${LOCAL_PORT}/v1/models" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

# Check if Mabel's Discord bot is running on this device.
local_bot_running() {
  pgrep -f 'chump.*--discord' >/dev/null 2>&1 || pgrep -f 'rust-agent.*--discord' >/dev/null 2>&1
}

# need_fix_local: set by run_diagnose when CHECK_LOCAL=1 and Pixel model or bot is down; used by run_once to run local fix.
need_fix_local=0

# ─────────────────────────────────────────────────────────────
# Diagnose
# ─────────────────────────────────────────────────────────────
run_diagnose() {
  log "=== Mabel Farmer diagnosis ==="
  local need_fix=0
  need_fix_local=0
  local mac_reachable=1

  # 1. Tailscale connectivity
  if check_tailscale_reachable; then
    log "  Tailscale (${MAC_IP}): reachable"
  else
    log "  Tailscale (${MAC_IP}): UNREACHABLE — Mac may be offline or Tailscale down"
    mac_reachable=0
    need_fix=1
  fi

  if [[ $mac_reachable -eq 1 ]]; then
    # 2. SSH
    if check_ssh_reachable; then
      log "  SSH: ok"
    else
      log "  SSH: FAILED (port ${MAC_SSH_PORT}) — sshd down or firewall?"
      need_fix=1
    fi

    # 3. Ollama
    if remote_ollama_ok; then
      log "  Ollama (${MAC_OLLAMA_PORT}): up"
    else
      log "  Ollama (${MAC_OLLAMA_PORT}): DOWN"
      need_fix=1
    fi

    # 4. Mac model (vLLM :8000)
    if remote_port_ok "$MAC_MODEL_PORT"; then
      log "  Mac model (vLLM :${MAC_MODEL_PORT}): up"
    else
      log "  Mac model (vLLM :${MAC_MODEL_PORT}): DOWN"
      need_fix=1
    fi

    # 5. Embed server
    if remote_embed_ok; then
      log "  Embed (${MAC_EMBED_PORT}): up"
    else
      log "  Embed (${MAC_EMBED_PORT}): down (may be optional)"
    fi

    # 6. Discord bot
    if remote_discord_running; then
      log "  Discord bot: running"
    else
      log "  Discord bot: NOT running"
      need_fix=1
    fi

    # 7. Chump health endpoint (optional)
    if [[ -n "$MAC_HEALTH_PORT" ]]; then
      local health
      health=$(curl -s --max-time 3 "http://${MAC_IP}:${MAC_HEALTH_PORT}/health" 2>/dev/null || echo "(unreachable)")
      log_only "  Chump health: $health"
    fi

    # 8. Heartbeat health (check recent log for failures)
    local hb_tail
    hb_tail=$(remote_heartbeat_health)
    if echo "$hb_tail" | grep -q "retry failed\|exit non-zero"; then
      log "  Heartbeat: recent failures detected"
      need_fix=1
    elif echo "$hb_tail" | grep -q "unreachable"; then
      log "  Heartbeat: could not read log"
    else
      log "  Heartbeat: ok (no recent failures)"
    fi
  fi

  # 9. Pixel model and bot (llama-server and Discord bot on this device)
  if [[ "$CHECK_LOCAL" == "1" ]]; then
    local local_ok=1
    if local_model_ok; then
      log "  Pixel model (llama-server :${LOCAL_PORT}): up"
    else
      log "  Pixel model (llama-server :${LOCAL_PORT}): DOWN"
      local_ok=0
    fi
    if local_bot_running; then
      log "  Pixel bot: running"
    else
      log "  Pixel bot: NOT running"
      local_ok=0
    fi
    [[ $local_ok -eq 0 ]] && need_fix_local=1
  fi

  log "=== End diagnosis (need_fix=$need_fix, need_fix_local=$need_fix_local) ==="
  return $need_fix
}

# ─────────────────────────────────────────────────────────────
# Fix: SSH into Mac and run farmer-brown.sh (or custom command)
# ─────────────────────────────────────────────────────────────
run_remote_fix() {
  local fix_cmd="${MABEL_FARMER_FIX_CMD:-cd $MAC_HOME && ./scripts/farmer-brown.sh}"
  log "Running remote fix on Mac: $fix_cmd"
  local output
  output=$($SSH_CMD "$fix_cmd" 2>&1) || true
  log_only "Remote fix output: $output"
  log "Remote fix complete."
}

# ─────────────────────────────────────────────────────────────
# Local fix: restart Pixel llama-server and bot (start-companion.sh)
# ─────────────────────────────────────────────────────────────
run_local_fix() {
  log "Running local fix on Pixel: kill stale bot/server, start-companion.sh"
  pkill -f 'chump.*--discord' 2>/dev/null || true
  pkill -f 'rust-agent.*--discord' 2>/dev/null || true
  pkill -f 'llama-server' 2>/dev/null || true
  sleep 2
  if [[ -x "$ROOT/start-companion.sh" ]]; then
    cd "$ROOT" && nohup ./start-companion.sh >> logs/companion.log 2>&1 </dev/null &
    log "start-companion.sh started in background."
    sleep 15
    if local_model_ok && local_bot_running; then
      log "Local fix: Pixel model and bot appear up."
    else
      run_diagnose || true
      log "Local fix: re-diagnosis above."
    fi
  else
    log "Local fix: start-companion.sh not found or not executable at $ROOT/start-companion.sh"
  fi
}

# ─────────────────────────────────────────────────────────────
# Notify: DM configured user via Chump --notify (stdin)
# ─────────────────────────────────────────────────────────────
notify_jeff() {
  local message="$1"
  if [[ "${MABEL_DISCORD_NOTIFY:-0}" != "1" ]]; then return 0; fi
  if [[ -z "${DISCORD_TOKEN:-}" ]] || [[ -z "${CHUMP_READY_DM_USER_ID:-}" ]]; then
    log_only "Would notify but DISCORD_TOKEN or CHUMP_READY_DM_USER_ID not set."
    return 0
  fi
  local bin=""
  if [[ -x "$ROOT/chump" ]]; then
    bin="$ROOT/chump"
  elif [[ -x "$ROOT/target/release/rust-agent" ]]; then
    bin="$ROOT/target/release/rust-agent"
  fi
  if [[ -n "$bin" ]]; then
    echo "$message" | "$bin" --notify 2>/dev/null || true
    log_only "Discord notification sent."
  else
    log_only "No chump binary found for notification (tried $ROOT/chump and $ROOT/target/release/rust-agent)."
  fi
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
INTERVAL="${MABEL_FARMER_INTERVAL:-}"

run_once() {
  if run_diagnose; then
    if [[ $need_fix_local -eq 1 ]]; then
      log "Mac ok but Pixel model or bot down."
      if $DO_FIX && [[ "$FIX_LOCAL" == "1" ]]; then
        run_local_fix
      fi
    else
      log "All checks ok."
    fi
  else
    log "Issues detected."
    local had_local_issue=$need_fix_local
    if $DO_FIX; then
      if check_ssh_reachable; then
        run_remote_fix
        sleep 10
        if run_diagnose; then
          log "Post-fix: Mac all clear."
        else
          log "Post-fix: Mac still unhealthy."
          notify_jeff "Mabel Farmer: Mac stack still unhealthy after remote fix. Check logs."
        fi
      else
        log "Cannot SSH to Mac — skipping remote fix."
        notify_jeff "Mabel Farmer: Mac unreachable at ${MAC_IP}. Tailscale down or Mac offline."
      fi
      # Local fix: run when Pixel model/bot was down (whether or not we ran remote fix)
      if [[ $had_local_issue -eq 1 ]] && [[ "$FIX_LOCAL" == "1" ]]; then
        run_local_fix
      fi
    else
      log "Diagnosis only (MABEL_FARMER_DIAGNOSE_ONLY=1); no fix applied."
    fi
  fi
}

if [[ -n "$INTERVAL" ]] && [[ "$INTERVAL" -gt 0 ]]; then
  log "Mabel Farmer loop every ${INTERVAL}s"
  while true; do
    run_once
    sleep "$INTERVAL"
  done
fi

run_once
