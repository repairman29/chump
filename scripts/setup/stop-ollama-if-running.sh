#!/usr/bin/env bash
# Stop Ollama so it does not contend with vLLM-MLX on the same Mac (Metal / RAM).
# Safe to run repeatedly; no-op if nothing is listening on 11434.
# Called from restart-vllm-*.sh and run-web when using local MLX (8000/8001).

set -euo pipefail
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)"
[[ -z "$code" ]] && code="000"
if [[ "$code" != "200" ]]; then
  if pgrep -f '[o]llama serve' >/dev/null 2>&1; then
    echo "[stop-ollama] No HTTP 200 on 11434 but ollama serve process found; sending TERM..."
    pkill -TERM -f 'ollama serve' 2>/dev/null || true
    sleep 2
    pkill -9 -f 'ollama serve' 2>/dev/null || true
  fi
  exit 0
fi
echo "[stop-ollama] Ollama is up on 11434; stopping for MLX-only operation..."
pkill -TERM -f 'ollama serve' 2>/dev/null || true
for _ in $(seq 1 15); do
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)"
  [[ -z "$c" ]] && c="000"
  [[ "$c" != "200" ]] && break
  sleep 1
done
if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)" == "200" ]]; then
  echo "[stop-ollama] Still up; sending KILL to ollama serve..."
  pkill -9 -f 'ollama serve' 2>/dev/null || true
  sleep 1
fi
echo "[stop-ollama] Done."
