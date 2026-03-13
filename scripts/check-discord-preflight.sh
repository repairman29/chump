#!/usr/bin/env bash
# Preflight check before starting Chump Discord: .env, DISCORD_TOKEN, no duplicate process, model server reachable.
# Run from repo root: ./scripts/check-discord-preflight.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"

FAIL=0

if [[ ! -f .env ]]; then
  echo "FAIL: .env not found. Copy .env.example to .env and set DISCORD_TOKEN."
  FAIL=1
else
  set -a
  source .env 2>/dev/null || true
  set +a
fi

if [[ -z "${DISCORD_TOKEN:-}" ]]; then
  echo "FAIL: DISCORD_TOKEN is not set. Set it in .env."
  FAIL=1
else
  echo "OK: DISCORD_TOKEN is set"
fi

if pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
  echo "FAIL: Chump Discord is already running. Stop it first (Chump Menu → Stop Chump, or pkill -f 'rust-agent.*--discord')."
  FAIL=1
else
  echo "OK: No duplicate Chump Discord process"
fi

# Model server: if OPENAI_API_BASE points to Ollama (11434), check /api/tags; else check /v1/models
BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
if [[ "$BASE" == *"11434"* ]]; then
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)
  if [[ "$code" != "200" ]]; then
    echo "FAIL: Ollama not reachable (got $code). Start: ollama serve && ollama pull qwen2.5:14b"
    FAIL=1
  else
    echo "OK: Ollama reachable at 11434"
  fi
else
  preflight_url="${BASE%/}/models"
  [[ "$preflight_url" != *"/v1/models" ]] && preflight_url="${BASE%/}/v1/models"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$preflight_url" 2>/dev/null || true)
  if [[ "$code" != "200" ]]; then
    echo "FAIL: Model server at $BASE not reachable (got $code)."
    if [[ "$BASE" == *"8000"* ]]; then
      echo "For vLLM-MLX on 8000: ./serve-vllm-mlx.sh or scripts/serve-vllm-mlx.sh"
    else
      echo "Start Ollama (ollama serve) or your configured server."
    fi
    FAIL=1
  else
    echo "OK: Model server reachable at $BASE"
  fi
fi

if [[ $FAIL -eq 1 ]]; then
  exit 1
fi
echo "Preflight OK. Run ./run-discord.sh or ./run-discord-ollama.sh"
echo "Reminder: In Discord Developer Portal → Bot → Privileged Gateway Intents, enable Message Content Intent."
