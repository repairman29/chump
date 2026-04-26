#!/usr/bin/env bash
# Oven tender: pre-warm the model (and optional worker) so Chump is ready at a chosen time.
# Runs warm-the-ovens.sh; if model is already warm, exits immediately. Schedule via cron/launchd
# (e.g. 7:45 if you want Chump ready by 8:00).
#
# Env:
#   CHUMP_HOME    Chump repo root (default: script dir/..).
#   WARM_PORT     Main model port (default 8000).
#   WARM_PORT_2   Optional second port (e.g. 8001).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/oven-tender.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

PORT_MAIN="${WARM_PORT:-8000}"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT_MAIN}/v1/models" 2>/dev/null || echo "000")

if [[ "$code" == "200" ]]; then
  log "Port $PORT_MAIN already warm; nothing to do."
  exit 0
fi

# M4-max: port 8000 = vLLM-MLX (restart it). Otherwise Ollama via warm-the-ovens.
# VLLM_MODEL from .env (sourced above) is used; script default is 14B.
if [[ "$PORT_MAIN" == "8000" ]]; then
  log "Port 8000 not ready; starting vLLM-MLX (VLLM_MODEL=${VLLM_MODEL:-14B})..."
  if [[ -x "$ROOT/serve-vllm-mlx.sh" ]]; then
    nohup "$ROOT/serve-vllm-mlx.sh" >> "$ROOT/logs/vllm-mlx-8000.log" 2>&1 &
    TIMEOUT="${WARM_TIMEOUT:-300}"
    deadline=$(($(date +%s) + TIMEOUT))
    while [[ $(date +%s) -lt $deadline ]]; do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
      [[ "$code" == "200" ]] && break
      sleep 5
    done
    if [[ "$code" == "200" ]]; then
      log "Oven tender: vLLM-MLX on 8000 ready."
      exit 0
    fi
    log "Oven tender: vLLM-MLX failed to become ready within ${TIMEOUT}s."
    exit 1
  else
    log "Oven tender: serve-vllm-mlx.sh not found or not executable."
    exit 1
  fi
fi

log "Port $PORT_MAIN not ready; running warm-the-ovens (Ollama)..."
if ./scripts/setup/warm-the-ovens.sh >> "$LOG" 2>&1; then
  log "Oven tender: warm-the-ovens completed."
  exit 0
else
  log "Oven tender: warm-the-ovens failed or timed out."
  exit 1
fi
