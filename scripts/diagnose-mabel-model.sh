#!/usr/bin/env bash
# Diagnose Mabel model on Pixel: model file, llama-server log, /v1/models and /v1/chat/completions.
# Usage: ./scripts/diagnose-mabel-model.sh [host]
# Env: PIXEL_SSH_HOST (default termux), PIXEL_SSH_PORT (default 8022).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

SSH_HOST="${1:-${PIXEL_SSH_HOST:-termux}}"
SSH_PORT="${PIXEL_SSH_PORT:-8022}"

echo "=== Mabel model diagnostic on $SSH_HOST:$SSH_PORT ==="
ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$SSH_PORT" "$SSH_HOST" '
  cd ~/chump 2>/dev/null || { echo "No ~/chump"; exit 1; }
  MODEL="${CHUMP_MODEL:-$HOME/models/Qwen3-4B-Q4_K_M.gguf}"
  PORT="${CHUMP_PORT:-8000}"

  echo "--- Model file ---"
  if [[ -f "$MODEL" ]]; then
    ls -la "$MODEL"
  else
    echo "Missing: $MODEL"
  fi

  echo "--- llama-server process ---"
  pgrep -af "llama-server" 2>/dev/null || echo "No llama-server process"

  echo "--- Last 25 lines of logs/llama-server.log ---"
  tail -25 logs/llama-server.log 2>/dev/null || echo "No log"

  echo "--- GET /v1/models ---"
  code=$(curl -s -o .diag_models.json -w "%{http_code}" --max-time 5 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || echo "000")
  echo "HTTP $code"
  [[ -f .diag_models.json ]] && head -c 500 .diag_models.json && echo ""; rm -f .diag_models.json

  echo "--- POST /v1/chat/completions (minimal) ---"
  code=$(curl -s -o .diag_chat.json -w "%{http_code}" --max-time 15 -X POST -H "Content-Type: application/json" \
    -d "{\"model\":\"default\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
    "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || echo "000")
  echo "HTTP $code"
  [[ -f .diag_chat.json ]] && head -c 400 .diag_chat.json && echo ""; rm -f .diag_chat.json
' 2>&1

echo "=== Done ==="
