#!/usr/bin/env bash
# Run Chump Discord with the full tool set: vLLM (8000), in-process embeddings, repo tools.
# Ensures vLLM is up, builds with inprocess-embed, sets CHUMP_REPO, then starts the bot.
# Use this when .env points at 8000 and you want read_file, memory (semantic), battle_qa, etc.
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
if pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
  echo "Chump Discord is already running."
  echo "Stop first: ./scripts/stop-chump-discord.sh   or   pkill -f 'rust-agent.*--discord'"
  exit 1
fi

# When using 8000, ensure vLLM is up before starting the bot
if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] || [[ "${OPENAI_API_BASE:-}" == *"localhost:8000"* ]]; then
  if [[ -x "$CHUMP_HOME/scripts/restart-vllm-if-down.sh" ]]; then
    "$CHUMP_HOME/scripts/restart-vllm-if-down.sh" || true
  fi
fi

echo "Building release with inprocess-embed (full tools)..."
cargo build --release --features inprocess-embed

mkdir -p logs
exec ./target/release/rust-agent --discord
