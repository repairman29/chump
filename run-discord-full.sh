#!/usr/bin/env bash
# Run Chump Discord with the full tool set: vLLM-MLX (local :8000 or :8001), in-process embeddings, repo tools.
# Ensures vLLM is up, builds with inprocess-embed, sets CHUMP_REPO, then starts the bot.
# Use this when .env points at http://127.0.0.1:8000/v1 or :8001/v1 and you want read_file, memory (semantic), battle_qa, etc.
# Only one instance should run. Stop first: ./scripts/stop-chump-discord.sh

set -e
cd "$(dirname "$0")"
export CHUMP_HOME="${CHUMP_HOME:-$(pwd)}"
export CHUMP_REPO="${CHUMP_REPO:-$CHUMP_HOME}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
export CHUMP_REPO="${CHUMP_REPO:-$CHUMP_HOME}"

if [[ -z "$DISCORD_TOKEN" ]]; then
  echo "DISCORD_TOKEN is not set. Set it in .env."
  exit 1
fi
if pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
  echo "Chump Discord is already running."
  echo "Stop first: ./scripts/stop-chump-discord.sh   or   pkill -f 'chump.*--discord'"
  exit 1
fi

if [[ -x "$CHUMP_HOME/scripts/inference-primary-mistralrs.sh" ]] && "$CHUMP_HOME/scripts/inference-primary-mistralrs.sh" 2>/dev/null; then
  echo "Primary inference: mistral.rs in-process — skipping vLLM-MLX / Ollama startup."
else
  MLX_PORT="$(bash "$CHUMP_HOME/scripts/openai-base-local-mlx-port.sh" 2>/dev/null || true)"
  if [[ "$MLX_PORT" == "8000" || "$MLX_PORT" == "8001" ]] && [[ -x "$CHUMP_HOME/scripts/stop-ollama-if-running.sh" ]]; then
    bash "$CHUMP_HOME/scripts/stop-ollama-if-running.sh" || true
  fi
  if [[ "$MLX_PORT" == "8000" ]] && [[ -x "$CHUMP_HOME/scripts/restart-vllm-if-down.sh" ]]; then
    "$CHUMP_HOME/scripts/restart-vllm-if-down.sh" || true
  elif [[ "$MLX_PORT" == "8001" ]] && [[ -x "$CHUMP_HOME/scripts/restart-vllm-8001-if-down.sh" ]]; then
    "$CHUMP_HOME/scripts/restart-vllm-8001-if-down.sh" || true
  fi
fi

echo "Building release with inprocess-embed (full tools)..."
cargo build --release --features inprocess-embed

mkdir -p logs
exec ./target/release/chump --discord
