#!/usr/bin/env bash
# If vLLM-MLX on 8000 is down (e.g. Python crashed with Metal OOM), start it again.
# Run manually after a crash or from cron/launchd every few minutes. Oven-tender does the same when scheduled.
# Usage: ./scripts/restart-vllm-if-down.sh
# (14B is the default; override with VLLM_MODEL=... if needed.)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ -x "$ROOT/scripts/stop-ollama-if-running.sh" ]]; then
  bash "$ROOT/scripts/stop-ollama-if-running.sh" || true
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
if [[ "$code" == "200" ]]; then
  echo "8000 already up (HTTP 200)."
  exit 0
fi
echo "8000 down (HTTP $code); starting vLLM-MLX..."
mkdir -p "$ROOT/logs"
# Capture OOM/crash context from the previous run before starting (log tail reflects crashed process).
"$ROOT/scripts/capture-oom-context.sh" 300 2>/dev/null || true
# Use 14B and stable memory defaults (override .env if needed).
VLLM_MODEL="${VLLM_MODEL:-mlx-community/Qwen2.5-14B-Instruct-4bit}"
export VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-1}"
export VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
export VLLM_CACHE_PERCENT="${VLLM_CACHE_PERCENT:-0.12}"
nohup env VLLM_MODEL="$VLLM_MODEL" VLLM_MAX_NUM_SEQS="$VLLM_MAX_NUM_SEQS" VLLM_MAX_TOKENS="$VLLM_MAX_TOKENS" VLLM_CACHE_PERCENT="$VLLM_CACHE_PERCENT" "$ROOT/serve-vllm-mlx.sh" >> "$ROOT/logs/vllm-mlx-8000.log" 2>&1 &
echo "Started. Waiting for 8000 ready (max 4 min)..."
for i in $(seq 1 48); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
  if [[ "$c" == "200" ]]; then
    echo "8000 ready after ${i}x5s."
    exit 0
  fi
  sleep 5
done
echo "Timeout: 8000 not ready after 4 min. Check logs/vllm-mlx-8000.log and GPU/Metal (e.g. OOM). Retry: $ROOT/scripts/restart-vllm-if-down.sh"
exit 1
