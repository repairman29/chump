#!/usr/bin/env bash
# If vLLM-MLX on 8001 is down, start the lighter default (7B) from serve-vllm-mlx-8001.sh.
# Pair with OPENAI_API_BASE=http://127.0.0.1:8001/v1 and OPENAI_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit
# Usage: ./scripts/restart-vllm-8001-if-down.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi
if [[ -x "$ROOT/scripts/stop-ollama-if-running.sh" ]]; then
  bash "$ROOT/scripts/stop-ollama-if-running.sh" || true
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8001/v1/models" 2>/dev/null || true)
[[ -z "$code" ]] && code="000"
if [[ "$code" == "200" ]]; then
  echo "8001 already up (HTTP 200)."
  exit 0
fi
echo "8001 down (HTTP $code); starting vLLM-MLX (lite)..."
mkdir -p "$ROOT/logs"
"$ROOT/scripts/capture-oom-context.sh" 300 2>/dev/null || true
VLLM_MODEL="${VLLM_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
export VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-1}"
export VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
export VLLM_CACHE_PERCENT="${VLLM_CACHE_PERCENT:-0.12}"
nohup env VLLM_MODEL="$VLLM_MODEL" VLLM_MAX_NUM_SEQS="$VLLM_MAX_NUM_SEQS" VLLM_MAX_TOKENS="$VLLM_MAX_TOKENS" VLLM_CACHE_PERCENT="$VLLM_CACHE_PERCENT" PORT=8001 "$ROOT/scripts/serve-vllm-mlx-8001.sh" >>"$ROOT/logs/vllm-mlx-8001.log" 2>&1 &
echo "Started. Waiting for 8001 ready (max 4 min)..."
for i in $(seq 1 48); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8001/v1/models" 2>/dev/null || true)
  [[ -z "$c" ]] && c="000"
  if [[ "$c" == "200" ]]; then
    echo "8001 ready after ${i}x5s."
    exit 0
  fi
  sleep 5
done
echo "Timeout: 8001 not ready after 4 min. Check logs/vllm-mlx-8001.log"
exit 1
