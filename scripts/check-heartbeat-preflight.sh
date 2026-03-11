#!/usr/bin/env bash
# Preflight for autonomy/heartbeat: is a model server reachable?
# Prints the port (8000, 8001, or 11434) and exits 0 if reachable; else exit 1.
# Respects OPENAI_API_BASE: if it points to Ollama (11434), check 11434 only; else check 8000 then 8001.

set -e
BASE="${OPENAI_API_BASE:-http://localhost:8000/v1}"

if [[ "$BASE" == *"11434"* ]]; then
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    echo "11434"
    exit 0
  fi
  exit 1
fi

for port in 8000 8001; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    echo "$port"
    exit 0
  fi
done
exit 1
