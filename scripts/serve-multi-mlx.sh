#!/usr/bin/env bash
# Start two vLLM-MLX servers so you can use two MLX models at once (e.g. 7B + 3B).
# Memory: ~16GB for 7B+3B; for 30B+7B you need ~24GB.
# Chump: use OPENAI_API_BASE=http://localhost:8000/v1 or :8001/v1 to pick the model.

set -e
cd "$(dirname "$0")/.."
export PATH="${HOME}/.local/bin:${PATH}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"

PORT_A="${PORT_A:-8000}"
PORT_B="${PORT_B:-8001}"
# Default: 7B on 8000, 3B on 8001. Override: MODEL_A=... MODEL_B=... ./scripts/serve-multi-mlx.sh
MODEL_A="${MODEL_A:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
MODEL_B="${MODEL_B:-mlx-community/Qwen2.5-3B-Instruct-4bit}"

if ! command -v vllm-mlx &>/dev/null; then
  echo "vllm-mlx not found. Install with: uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'"
  exit 1
fi

cleanup() {
  echo "Stopping servers..."
  kill "$PID_A" 2>/dev/null || true
  kill "$PID_B" 2>/dev/null || true
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "Starting model A: $MODEL_A on port $PORT_A"
vllm-mlx serve "$MODEL_A" --port "$PORT_A" &
PID_A=$!
sleep 5
echo "Starting model B: $MODEL_B on port $PORT_B"
vllm-mlx serve "$MODEL_B" --port "$PORT_B" &
PID_B=$!
echo "Both running. Chump: OPENAI_API_BASE=http://localhost:$PORT_A/v1 or :$PORT_B/v1. Ctrl+C to stop both."
wait
