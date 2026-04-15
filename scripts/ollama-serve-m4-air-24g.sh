#!/usr/bin/env bash
# Ollama tuned for **24 GB unified** Macs (e.g. MacBook Air M4): small context, one
# in-flight request at a time — fewer OOMs when Chump + IDE + browser are open.
#
# Usage (from repo root):
#   ./scripts/ollama-serve-m4-air-24g.sh
# Stop: pkill -f "ollama serve"  (or use ./scripts/ollama-restart.sh per docs)
#
# Override any var when invoking, e.g.:
#   OLLAMA_CONTEXT_LENGTH=4096 ./scripts/ollama-serve-m4-air-24g.sh
set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
mkdir -p "$ROOT/logs"

export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-2048}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"

LOG="${OLLAMA_SERVE_LOG:-$ROOT/logs/ollama-serve.log}"

echo "Starting Ollama (24G-class profile: ctx=$OLLAMA_CONTEXT_LENGTH keep_alive=$OLLAMA_KEEP_ALIVE parallel=$OLLAMA_NUM_PARALLEL)..."
echo "Log: $LOG"
echo "See docs/OLLAMA_SPEED.md §6 (MacBook Air M4 24 GB)."

nohup ollama serve >>"$LOG" 2>&1 &
sleep 2
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:11434/api/tags" | grep -q 200; then
  echo "Ollama is up."
else
  echo "Ollama may still be starting. Check: tail -f \"$LOG\""
fi
