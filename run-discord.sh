#!/usr/bin/env bash
# Run the Discord bot. Loads DISCORD_TOKEN from .env if present.
# Enable "Message Content Intent" in Discord Developer Portal → Bot (see docs/DISCORD_TROUBLESHOOTING.md).
# Local inference: Ollama by default (no Python in agent runtime). Start Ollama and pull Qwen 2.5 14B:
#   ollama serve && ollama pull qwen2.5:14b
# Override OPENAI_API_BASE for another endpoint if needed.
# Only one instance should run; multiple instances cause duplicate replies to every message.
# For full tools (vLLM 8000 + repo + in-process embed): use ./run-discord-full.sh instead.

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
  echo "DISCORD_TOKEN is not set. Set it in .env or export it."
  exit 1
fi
if pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
  echo "Chump Discord is already running (multiple instances cause duplicate replies)."
  echo "Stop first: ./scripts/stop-chump-discord.sh   or   pkill -f 'chump.*--discord'"
  exit 1
fi
# Default: Ollama at localhost (Qwen 2.5 14B).
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
# Ollama context size (only when using Ollama). 4096 = good quality; lower saves RAM.
case "${OPENAI_API_BASE}" in *11434*) export OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-4096}" ;; esac
# Single model by default. For a second worker, set CHUMP_WORKER_API_BASE and CHUMP_DELEGATE=1.
if [[ -n "${CHUMP_DELEGATE}" ]] && [[ -n "${CHUMP_WORKER_API_BASE:-}" ]]; then
  export CHUMP_WORKER_MODEL="${CHUMP_WORKER_MODEL:-default}"
fi
mkdir -p logs
# Prefer repo release binary so one consistent Chump runs (avoid cargo from another env building to a different target).
if [[ -x ./target/release/chump ]]; then
  exec ./target/release/chump --discord
elif [[ -x ./target/debug/chump ]]; then
  exec ./target/debug/chump --discord
fi
exec cargo run -- --discord
