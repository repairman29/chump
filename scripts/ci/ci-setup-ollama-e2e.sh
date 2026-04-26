#!/usr/bin/env bash
# Install Ollama, start serve, pull a model — for CI PWA Playwright (real LLM, slow-friendly).
# Usage: source from CI or run: bash scripts/ci/ci-setup-ollama-e2e.sh
# Env:
#   CHUMP_CI_OLLAMA_MODEL  default qwen2.5:7b (smaller than 14b for CI time; still local Ollama path)
set -euo pipefail

MODEL="${CHUMP_CI_OLLAMA_MODEL:-qwen2.5:7b}"

if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "ci-setup-ollama-e2e: Ollama already listening on 11434"
else
  echo "ci-setup-ollama-e2e: starting ollama serve"
  nohup ollama serve >/tmp/ollama-serve-ci.log 2>&1 &
  for i in $(seq 1 90); do
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      echo "ci-setup-ollama-e2e: ollama ready after ${i}s"
      break
    fi
    sleep 2
  done
fi

curl -sf http://127.0.0.1:11434/api/tags >/dev/null || {
  echo "ci-setup-ollama-e2e: FAIL ollama not reachable on 11434" >&2
  tail -80 /tmp/ollama-serve-ci.log 2>/dev/null || true
  exit 1
}

echo "ci-setup-ollama-e2e: pulling $MODEL (first run may take several minutes)"
ollama pull "$MODEL"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:11434/v1/models || echo 000)
[[ "$code" == "200" ]] || {
  echo "ci-setup-ollama-e2e: FAIL Ollama /v1/models HTTP $code" >&2
  exit 1
}
echo "ci-setup-ollama-e2e: OK model=$MODEL"
