#!/usr/bin/env bash
# Restart Ollama so it actually returns RAM to the OS. Unloading models (keep_alive=0)
# often does not free memory; killing and restarting the process does.
# Usage: ./scripts/ollama-restart.sh
# Starts ollama serve in the background after killing existing ollama processes.

set -e
echo "Stopping Ollama..."
pkill -f ollama 2>/dev/null || true
sleep 2
# Ensure nothing is still bound to 11434
if command -v lsof >/dev/null 2>&1; then
  if lsof -i :11434 2>/dev/null | grep -q .; then
    echo "Port 11434 still in use; waiting..."
    sleep 3
  fi
fi
echo "Starting Ollama (background)..."
nohup ollama serve > /tmp/ollama-serve.log 2>&1 &
sleep 2
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:11434/api/tags" | grep -q 200; then
  echo "Ollama is back up. RAM should be freed (check Activity Monitor)."
else
  echo "Ollama may still be starting. Check: tail -f /tmp/ollama-serve.log"
fi
