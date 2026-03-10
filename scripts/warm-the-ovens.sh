#!/usr/bin/env bash
# Start MLX model server(s) if not already running. Used when CHUMP_WARM_SERVERS=1 so Chump
# can "warm the ovens" on first Discord message instead of keeping servers always on.
# Requires: run from rust-agent dir, or set CHUMP_HOME to rust-agent.
# Main port 8000 uses serve-vllm-mlx.sh default (30B ~17GB). To reduce memory (e.g. if Python
# embed server crashes): VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit ./scripts/warm-the-ovens.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"

PORT_MAIN="${WARM_PORT:-8000}"
PORT_SECOND="${WARM_PORT_2:-}"
TIMEOUT="${WARM_TIMEOUT:-180}"

ready() {
  local port=$1
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || true
}

# Already up?
if [[ "$(ready $PORT_MAIN)" == "200" ]]; then
  echo "Port $PORT_MAIN already ready."
  exit 0
fi

mkdir -p "$ROOT/logs"
echo "Warming the ovens: starting vLLM-MLX on port $PORT_MAIN ..."
PORT="$PORT_MAIN" nohup ./serve-vllm-mlx.sh >> "$ROOT/logs/warm-ovens.log" 2>&1 &
PID=$!
echo $PID > "$ROOT/logs/warm-ovens.pid"

# Optional second server
if [[ -n "$PORT_SECOND" ]]; then
  echo "Starting second model on port $PORT_SECOND ..."
  nohup env PORT="$PORT_SECOND" VLLM_MODEL="${WARM_MODEL_2:-mlx-community/Qwen2.5-7B-Instruct-4bit}" ./serve-vllm-mlx.sh >> "$ROOT/logs/warm-ovens-2.log" 2>&1 &
  echo $! >> "$ROOT/logs/warm-ovens.pid"
fi

# Wait for main port
deadline=$(($(date +%s) + TIMEOUT))
while [[ $(date +%s) -lt $deadline ]]; do
  if [[ "$(ready $PORT_MAIN)" == "200" ]]; then
    echo "Port $PORT_MAIN ready."
    exit 0
  fi
  sleep 5
done

echo "Timeout waiting for port $PORT_MAIN"
exit 1
