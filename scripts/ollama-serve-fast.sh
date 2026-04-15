#!/usr/bin/env bash
# Start Ollama with speed-focused env vars: smaller context, keep model warm, 2 parallel.
# **24 GB unified MacBook** (e.g. M4 Air): prefer ./scripts/ollama-serve-m4-air-24g.sh (parallel 1) — docs/OLLAMA_SPEED.md §6.
# Run from repo root or anywhere. Logs: /tmp/ollama-serve.log
# Stop with: pkill -f ollama

set -e
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-2048}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-2}"

echo "Starting Ollama (speed profile: ctx=$OLLAMA_CONTEXT_LENGTH keep_alive=$OLLAMA_KEEP_ALIVE parallel=$OLLAMA_NUM_PARALLEL)..."
nohup ollama serve > /tmp/ollama-serve.log 2>&1 &
sleep 2
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:11434/api/tags" | grep -q 200; then
  echo "Ollama is up. See docs/OLLAMA_SPEED.md for more tuning."
else
  echo "Ollama may still be starting. Check: tail -f /tmp/ollama-serve.log"
fi
