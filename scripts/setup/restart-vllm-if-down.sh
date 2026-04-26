#!/usr/bin/env bash
# If vLLM-MLX on 8000 is down (e.g. Python crashed with Metal OOM), start it again.
# Run manually after a crash or from cron/launchd every few minutes. Oven-tender does the same when scheduled.
# Usage: ./scripts/setup/restart-vllm-if-down.sh
# (14B is the default; override with VLLM_MODEL=... if needed.)
#
# Avoid spawning a second vllm-mlx while the first is still downloading weights (HF can take 10+ min without
# HF_TOKEN). We skip start if a vllm-mlx serve process is already present, and use an atomic lock so two cron
# invocations cannot both pass the HTTP check and double-start in the same second.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"
LOCKDIR="$ROOT/logs/vllm-restart-if-down.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "Another restart-vllm-if-down instance is running (lock: $LOCKDIR)."
  echo "If none is running after a crash, remove the lock: rmdir \"$LOCKDIR\""
  exit 0
fi
cleanup_lock() { rmdir "$LOCKDIR" 2>/dev/null || true; }
trap cleanup_lock EXIT

if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ -x "$ROOT/scripts/setup/stop-ollama-if-running.sh" ]]; then
  bash "$ROOT/scripts/setup/stop-ollama-if-running.sh" || true
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
if [[ "$code" == "200" ]]; then
  echo "8000 already up (HTTP 200)."
  exit 0
fi
if pgrep -f 'vllm-mlx serve' >/dev/null 2>&1; then
  echo "vLLM-MLX is already running or loading (process present); not starting a duplicate. Tail logs/vllm-mlx-8000.log until HTTP 200."
  exit 0
fi
echo "8000 down (HTTP $code); starting vLLM-MLX..."
# Capture OOM/crash context from the previous run before starting (log tail reflects crashed process).
"$ROOT/scripts/dev/capture-oom-context.sh" 300 2>/dev/null || true
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
echo "Timeout: 8000 not ready after 4 min (first-time HF download often needs longer). Check logs/vllm-mlx-8000.log; curl http://127.0.0.1:8000/v1/models until 200. Set HF_TOKEN in .env for faster pulls. Retry: $ROOT/scripts/setup/restart-vllm-if-down.sh"
exit 1
