#!/usr/bin/env bash
# Start Ollama if not already running. Used when CHUMP_WARM_SERVERS=1 so Chump
# can have a model ready on first Discord message.
# Requires: ollama installed (brew install ollama). Pull a model first: ollama pull qwen2.5:14b

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

OLLAMA_PORT="${OLLAMA_HOST:-http://127.0.0.1:11434}"
# Strip protocol for curl
PORT_CHECK="127.0.0.1:11434"

ready() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://${PORT_CHECK}/api/tags" 2>/dev/null || true
}

# Already up?
if [[ "$(ready)" == "200" ]]; then
  echo "Ollama already ready on 11434."
  exit 0
fi

mkdir -p "$ROOT/logs"
echo "Warming the ovens: starting Ollama ..."
nohup ollama serve >> "$ROOT/logs/warm-ovens.log" 2>&1 &
echo $! > "$ROOT/logs/warm-ovens.pid"

TIMEOUT="${WARM_TIMEOUT:-120}"
deadline=$(($(date +%s) + TIMEOUT))
while [[ $(date +%s) -lt $deadline ]]; do
  if [[ "$(ready)" == "200" ]]; then
    echo "Ollama ready on 11434."
    exit 0
  fi
  sleep 3
done

echo "Timeout waiting for Ollama on 11434."
exit 1
