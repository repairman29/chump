#!/usr/bin/env bash
# One-time local setup: .env, Ollama check, and how to run Discord + autonomy tests.
# Run from repo root: ./scripts/setup-local.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

echo "=== Chump local setup (repo: $ROOT) ==="
mkdir -p logs
# Ensure role scripts (and others) are executable so ChumpMenu Roles can run them
for f in scripts/farmer-brown.sh scripts/heartbeat-shepherd.sh scripts/memory-keeper.sh scripts/sentinel.sh scripts/oven-tender.sh scripts/check-discord-preflight.sh scripts/run-autonomy-tests.sh run-web.sh; do
  [[ -f "$f" ]] && chmod +x "$f"
done

# 1. .env
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example."
  echo "  → For Discord: uncomment DISCORD_TOKEN in .env (Developer Portal → Bot → Reset Token). For web/CLI-only golden path, leave it commented."
  echo "  → Optional: TAVILY_API_KEY for web search and autonomy tiers 2+."
else
  echo ".env already exists."
fi

# 2. Ollama
if ! command -v ollama >/dev/null 2>&1; then
  echo "Ollama not in PATH. Install from https://ollama.com"
else
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)
  if [[ "$code" != "200" ]]; then
    echo "Start Ollama and pull the default model:"
    echo "  ollama serve"
    echo "  ollama pull qwen2.5:14b"
  else
    if ollama list 2>/dev/null | grep -q "qwen2.5:14b"; then
      echo "Ollama is running and qwen2.5:14b is available."
    else
      echo "Ollama is running. Pull the default model: ollama pull qwen2.5:14b"
    fi
  fi
fi

# 3. Discord preflight (informational)
echo ""
echo "Discord: run preflight then start the bot:"
echo "  ./scripts/check-discord-preflight.sh"
echo "  ./run-discord.sh   # or ./run-discord-ollama.sh"
echo "  ./run-web.sh       # PWA (ensures model on 8000 if .env points there)"
echo ""
echo "Autonomy tests (Chump Olympics) with Ollama:"
echo "  OPENAI_API_BASE=http://localhost:11434/v1 OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:14b ./scripts/run-autonomy-tests.sh"
echo ""
echo "CLI one-shot: ./run-local.sh --chump \"Hello\""
