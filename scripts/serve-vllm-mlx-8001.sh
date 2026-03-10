#!/usr/bin/env bash
# Option 1 second server: 7B on port 8001. Run with serve-vllm-mlx.sh (30B on 8000) in another terminal.
# Chump: OPENAI_API_BASE=http://localhost:8001/v1 for this model.

set -e
cd "$(dirname "$0")/.."
export PATH="${HOME}/.local/bin:${PATH}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"

VLLM_MODEL="${VLLM_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
PORT="${PORT:-8001}"

if ! command -v vllm-mlx &>/dev/null; then
  echo "vllm-mlx not found. Install with: uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'"
  exit 1
fi

echo "Starting vLLM-MLX (second model): $VLLM_MODEL on port $PORT"
exec vllm-mlx serve "$VLLM_MODEL" --port "$PORT"
