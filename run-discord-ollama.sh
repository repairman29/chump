#!/usr/bin/env bash
# Run the Discord bot against Ollama (explicit). Same as run-discord.sh default; use if you want to force Ollama and check it's up.
#
# Prereqs: Ollama installed (ollama.com or brew install ollama), ollama serve, ollama pull qwen2.5:14b.
# .env must have DISCORD_TOKEN.
#
# Usage: ./run-discord-ollama.sh

set -e
cd "$(dirname "$0")"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

if [[ -z "$DISCORD_TOKEN" ]]; then
  echo "DISCORD_TOKEN is not set. Set it in .env." >&2
  exit 1
fi
if pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
  echo "Chump Discord is already running. Stop it first (Chump Menu → Stop Chump, or pkill -f 'rust-agent.*--discord')." >&2
  exit 1
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
# Single model; no worker endpoint
unset CHUMP_WORKER_API_BASE

# Quick check that Ollama is up
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)
if [[ "$code" != "200" ]]; then
  echo "Ollama not reachable (got $code). Start it: ollama serve" >&2
  echo "Then pull a model: ollama pull qwen2.5:14b" >&2
  exit 1
fi

echo "Using Ollama at $OPENAI_API_BASE (model: $OPENAI_MODEL). No Python in agent runtime."
exec cargo run -- --discord
