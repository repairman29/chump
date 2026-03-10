#!/usr/bin/env bash
# Run the Discord bot. Loads DISCORD_TOKEN from .env if present.
# Start your local model first (e.g. ./serve-vllm-mlx.sh or Ollama).
# Only one instance should run; multiple instances cause duplicate replies to every message.

set -e
cd "$(dirname "$0")"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
if [[ -z "$DISCORD_TOKEN" ]]; then
  echo "DISCORD_TOKEN is not set. Set it in .env or export it."
  exit 1
fi
if pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
  echo "Chump Discord is already running. Stop it first (Chump Menu → Stop Chump, or pkill -f 'rust-agent.*--discord') to avoid duplicate replies."
  exit 1
fi
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:8000/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-default}"
# Delegate tool: worker uses CHUMP_WORKER_API_BASE when set, else OPENAI_API_BASE (8000).
# For 30B-only (no 8001) leave CHUMP_WORKER_API_BASE unset so worker uses 8000. For 7B worker on 8001, set CHUMP_WORKER_API_BASE=http://localhost:8001/v1 and run serve-vllm-mlx-8001.sh.
if [[ -n "${CHUMP_DELEGATE}" ]] && [[ -n "${CHUMP_WORKER_API_BASE:-}" ]]; then
  export CHUMP_WORKER_MODEL="${CHUMP_WORKER_MODEL:-default}"
fi
exec cargo run -- --discord
