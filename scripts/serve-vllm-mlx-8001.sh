#!/usr/bin/env bash
# vLLM-MLX on port 8001 — lighter default (7B 4-bit) for smaller unified-memory Macs or a second server
# while 14B stays on 8000. See docs/INFERENCE_PROFILES.md (lite MLX on 8001).
#
# Usage:
#   ./scripts/serve-vllm-mlx-8001.sh
# Env: VLLM_MODEL (default 7B), PORT (default 8001), VLLM_MAX_NUM_SEQS, VLLM_MAX_TOKENS, VLLM_CACHE_PERCENT
#
# Chump .env when using only this server:
#   OPENAI_API_BASE=http://127.0.0.1:8001/v1
#   OPENAI_API_KEY=not-needed
#   OPENAI_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ -x "$ROOT/scripts/stop-ollama-if-running.sh" ]]; then
  bash "$ROOT/scripts/stop-ollama-if-running.sh" || true
fi

VLLM_MODEL="${VLLM_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
PORT="${PORT:-8001}"
export PATH="${HOME}/.local/bin:${PATH}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"

VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-1}"
VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
VLLM_CACHE_PERCENT="${VLLM_CACHE_PERCENT:-0.12}"

if ! command -v vllm-mlx &>/dev/null; then
  echo "vllm-mlx not found. Install with:"
  echo "  uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'"
  exit 1
fi

echo "Starting vLLM-MLX (lite): $VLLM_MODEL on port $PORT (max_num_seqs=$VLLM_MAX_NUM_SEQS, max_tokens=$VLLM_MAX_TOKENS, cache=$VLLM_CACHE_PERCENT)"
exec vllm-mlx serve "$VLLM_MODEL" --port "$PORT" \
  --max-num-seqs "$VLLM_MAX_NUM_SEQS" \
  --max-tokens "$VLLM_MAX_TOKENS" \
  --cache-memory-percent "$VLLM_CACHE_PERCENT"
