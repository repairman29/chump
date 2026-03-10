#!/usr/bin/env bash
# Start vLLM-MLX with the plan-recommended 30B 4-bit DWQ model (best quality on Apple Silicon).
# Requires: vLLM-MLX installed (see README — uv tool install git+https://github.com/waybarrios/vllm-mlx.git).
#
# If you see "close to the maximum recommended size" or OOM (e.g. 24GB Mac with Cursor):
#   - Use a smaller model: export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit
#   - Quit other heavy apps (Cursor, browsers) and retry; vllm-mlx has no context-length flag.
#   ./serve-vllm-mlx.sh
# If the Python embed server (port 18765) keeps crashing (OOM): 30B uses ~17 GB; running 30B+7B
#   leaves little RAM for embed. Use a smaller 8000 model (e.g. 7B above) or use in-process
#   embeddings (cargo build --features inprocess-embed, no CHUMP_EMBED_URL).

set -e
VLLM_MODEL="${VLLM_MODEL:-mlx-community/Qwen3-30B-A3B-4bit-DWQ}"
PORT="${PORT:-8000}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-}"

# Prefer uv-installed tool (e.g. ~/.local/bin)
export PATH="${HOME}/.local/bin:${PATH}"

# Reduce Python/Metal crashes on macOS (fork-safety + optional CPU fallback)
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"
# If Python still crashes (e.g. NSRangeException in Metal), force CPU and retry:
#   export MLX_DEVICE=cpu
#   ./serve-vllm-mlx.sh

if ! command -v vllm-mlx &>/dev/null; then
  echo "vllm-mlx not found. Install with:"
  echo "  uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'"
  echo "Or: pip install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'"
  exit 1
fi

# vllm-mlx does not support --max-model-len; use a smaller model (e.g. 7B) if OOM.
# VLLM_MAX_MODEL_LEN is kept for doc/compat but not passed to vllm-mlx.
if [[ -n "$VLLM_MAX_MODEL_LEN" ]]; then
  echo "Starting vLLM-MLX: $VLLM_MODEL on port $PORT (VLLM_MAX_MODEL_LEN=$VLLM_MAX_MODEL_LEN not supported by vllm-mlx; use 7B if OOM)"
else
  echo "Starting vLLM-MLX: $VLLM_MODEL on port $PORT (first run may download ~17GB)"
fi
exec vllm-mlx serve "$VLLM_MODEL" --port "$PORT"
