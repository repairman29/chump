#!/usr/bin/env bash
# Preflight check before starting Chump Discord: .env, DISCORD_TOKEN, no duplicate process, model server reachable.
# Run from repo root: ./scripts/check-discord-preflight.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

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
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${BASE%/}/models" 2>/dev/null || true)
  if [[ "$code" != "200" ]]; then
    echo "FAIL: Model server at $BASE not reachable (got $code). Start your model server (e.g. ./serve-vllm-mlx.sh or Ollama)."
    FAIL=1
  else
    echo "OK: Model server reachable at $BASE"
  fi
fi

if [[ $FAIL -eq 1 ]]; then
  exit 1
fi
echo "Preflight OK. Run ./run-discord.sh or ./run-discord-ollama.sh"
