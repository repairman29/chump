#!/usr/bin/env bash
# Keep Chump stack online: Ollama (11434), optional embed (18765), optional Discord bot.
# Farmer Brown calls this after diagnosing/killing stale processes.
#
# Env (optional, from .env):
#   CHUMP_KEEPALIVE_EMBED=1     Start embed server on CHUMP_EMBED_PORT (default 18765) if not up.
#   CHUMP_KEEPALIVE_DISCORD=1   Start Chump Discord if DISCORD_TOKEN set and not running.
#   CHUMP_KEEPALIVE_WORKER=1    Not used here; Farmer Brown handles worker port.
#   CHUMP_KEEPALIVE_INTERVAL=N  If set, loop every N seconds; otherwise run once.
#
# Logs: logs/keep-chump-online.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

LOG="$ROOT/logs/keep-chump-online.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# M4-max: OPENAI_API_BASE on 8000 => no Ollama, no embed (vLLM-MLX + in-process embed).
USE_OLLAMA=1
USE_EMBED=1
USE_VLLM_8000=0
if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] || [[ "${OPENAI_API_BASE:-}" == *"localhost:8000"* ]]; then
  USE_OLLAMA=0
  USE_EMBED=0
  USE_VLLM_8000=1
  log "M4-max config (8000): skipping Ollama and embed; will keep vLLM on 8000 up."
fi

# --- vLLM (8000) in max mode: ensure model server is up ---
vllm_8000_ready() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:8000/v1/models' 2>/dev/null)" == "200" ]]
}

if [[ "$USE_VLLM_8000" == "1" ]]; then
  keep_8000_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:8000/v1/models' 2>/dev/null || true)
  # #region agent log
  echo "{\"sessionId\":\"ee095d\",\"hypothesisId\":\"H3\",\"location\":\"keep-chump-online.sh:8000_check\",\"message\":\"keep-chump 8000 check\",\"data\":{\"http_code\":\"$keep_8000_code\",\"ts_sec\":$(date +%s)},\"timestamp\":$(date +%s)000}" >> "/Users/jeffadkins/Projects/Maclawd/.cursor/debug-ee095d.log" 2>/dev/null || true
  # #endregion
  if vllm_8000_ready; then
    log "vLLM (8000) already up."
  else
    log "vLLM (8000) not ready; starting..."
    # #region agent log
    echo "{\"sessionId\":\"ee095d\",\"hypothesisId\":\"H3\",\"location\":\"keep-chump-online.sh:starting\",\"message\":\"keep-chump starting vLLM\",\"data\":{\"ts_sec\":$(date +%s)},\"timestamp\":$(date +%s)000}" >> "/Users/jeffadkins/Projects/Maclawd/.cursor/debug-ee095d.log" 2>/dev/null || true
    # #endregion
    if [[ -x "$ROOT/scripts/restart-vllm-if-down.sh" ]]; then
      "$ROOT/scripts/restart-vllm-if-down.sh" >> "$LOG" 2>&1 || true
      sleep 5
      if vllm_8000_ready; then
        log "vLLM (8000) started."
      else
        log "vLLM (8000) may still be loading; check logs/vllm-mlx-8000.log"
      fi
    else
      nohup "$ROOT/serve-vllm-mlx.sh" >> "$ROOT/logs/vllm-mlx-8000.log" 2>&1 &
      log "vLLM (8000) start triggered (logs: logs/vllm-mlx-8000.log)."
    fi
  fi
fi

# --- Ollama (11434) ---
ollama_ready() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true
}

if [[ "$USE_OLLAMA" == "1" ]]; then
  if [[ "$(ollama_ready)" != "200" ]]; then
    log "Starting Ollama..."
    nohup ollama serve >> "$ROOT/logs/ollama-serve.log" 2>&1 &
    echo $! >> "$LOG"
    for i in $(seq 1 40); do
      [[ "$(ollama_ready)" == "200" ]] && break
      sleep 3
    done
    if [[ "$(ollama_ready)" == "200" ]]; then
      log "Ollama ready on 11434."
    else
      log "Ollama failed to become ready; check logs/ollama-serve.log"
    fi
  else
    log "Ollama already up (11434)."
  fi
fi

# --- Embed (optional) ---
if [[ "$USE_EMBED" == "1" ]] && [[ "${CHUMP_KEEPALIVE_EMBED:-0}" == "1" ]]; then
  EMBED_PORT="${CHUMP_EMBED_PORT:-18765}"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${EMBED_PORT}/" 2>/dev/null || echo "000")
  if [[ "$code" != "200" ]] && [[ "$code" != "404" ]] && [[ "$code" != "405" ]]; then
    log "Starting embed server on ${EMBED_PORT}..."
    if [[ -x "$ROOT/scripts/start-embed-server.sh" ]]; then
      nohup "$ROOT/scripts/start-embed-server.sh" >> "$ROOT/logs/embed-server.log" 2>&1 &
      sleep 5
    else
      log "start-embed-server.sh not found or not executable; skipping embed."
    fi
  else
    log "Embed already up (${EMBED_PORT})."
  fi
fi

# --- Chump Discord (optional; default on in max mode so stack stays up) ---
[[ "$USE_VLLM_8000" == "1" ]] && [[ -z "${CHUMP_KEEPALIVE_DISCORD:-}" ]] && CHUMP_KEEPALIVE_DISCORD=1
if [[ "${CHUMP_KEEPALIVE_DISCORD:-0}" == "1" ]] && [[ -n "${DISCORD_TOKEN:-}" ]]; then
  if pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
    log "Chump Discord already running."
  else
    log "Starting Chump Discord..."
    nohup "$ROOT/run-discord.sh" >> "$ROOT/logs/discord.log" 2>&1 &
    log "Chump Discord started (logs: logs/discord.log)."
  fi
else
  if [[ "${CHUMP_KEEPALIVE_DISCORD:-0}" == "1" ]] && [[ -z "${DISCORD_TOKEN:-}" ]]; then
    log "CHUMP_KEEPALIVE_DISCORD=1 but DISCORD_TOKEN not set; skipping Discord."
  fi
fi

# --- Optional loop ---
INTERVAL="${CHUMP_KEEPALIVE_INTERVAL:-}"
if [[ -n "$INTERVAL" ]] && [[ "$INTERVAL" -gt 0 ]]; then
  log "Looping every ${INTERVAL}s (Ctrl+C to stop)."
  while true; do
    sleep "$INTERVAL"
    log "=== Next pass ==="
    # vLLM (8000) in max mode
    if [[ "$USE_VLLM_8000" == "1" ]] && ! vllm_8000_ready; then
      log "vLLM (8000) down; starting..."
      [[ -x "$ROOT/scripts/restart-vllm-if-down.sh" ]] && "$ROOT/scripts/restart-vllm-if-down.sh" >> "$LOG" 2>&1 || true
    fi
    # Ollama (skip when M4-max / 8000)
    if [[ "$USE_OLLAMA" == "1" ]] && [[ "$(ollama_ready)" != "200" ]]; then
      log "Ollama down; starting..."
      nohup ollama serve >> "$ROOT/logs/ollama-serve.log" 2>&1 &
    fi
    # Embed (skip when M4-max)
    if [[ "$USE_EMBED" == "1" ]] && [[ "${CHUMP_KEEPALIVE_EMBED:-0}" == "1" ]]; then
      EMBED_PORT="${CHUMP_EMBED_PORT:-18765}"
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${EMBED_PORT}/" 2>/dev/null || echo "000")
      if [[ "$code" != "200" ]] && [[ "$code" != "404" ]] && [[ "$code" != "405" ]]; then
        [[ -x "$ROOT/scripts/start-embed-server.sh" ]] && nohup "$ROOT/scripts/start-embed-server.sh" >> "$ROOT/logs/embed-server.log" 2>&1 &
      fi
    fi
    # Discord
    if [[ "${CHUMP_KEEPALIVE_DISCORD:-0}" == "1" ]] && [[ -n "${DISCORD_TOKEN:-}" ]]; then
      if ! pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
        log "Chump Discord down; starting..."
        nohup "$ROOT/run-discord.sh" >> "$ROOT/logs/discord.log" 2>&1 &
      fi
    fi
  done
fi

log "keep-chump-online pass done."
