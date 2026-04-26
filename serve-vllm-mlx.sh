#!/usr/bin/env bash
# Start vLLM-MLX with 14B 4-bit (default; runs on typical Apple Silicon without Metal OOM).
# For a lighter single-server profile on port 8001 (7B default), use ./scripts/serve-vllm-mlx-8001.sh (see docs/operations/INFERENCE_PROFILES.md §1a).
# Requires: vLLM-MLX installed (see README — uv tool install git+https://github.com/waybarrios/vllm-mlx.git).
#
# First-time run: 14B downloads ~8–9GB from Hugging Face. Without HF_TOKEN downloads are rate-limited and can take 30+ min. Set HF_TOKEN in .env for faster downloads. Or pre-download in another terminal: huggingface-cli download mlx-community/Qwen2.5-14B-Instruct-4bit
#
# If you see "close to the maximum recommended size" or OOM (e.g. 24GB Mac with Cursor):
#   - 7B:  export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit
#   - 7B:  export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit   (lightest)
#   - 9B:  export VLLM_MODEL=mlx-community/Qwen3.5-9B-OptiQ-4bit      (Qwen3.5 text-gen; ~5.7GB — NOT the VLM repo Qwen3.5-9B-MLX-4bit)
#   - 14B: default (below). Alternative: export VLLM_MODEL=mlx-community/Qwen3-14B-4bit
#   - 20B: export VLLM_MODEL=mlx-community/gpt-oss-20b-MXFP4-Q4       (different family)
#   - Quit other heavy apps (Chump mode) and retry; vllm-mlx has no context-length flag.
#   ./serve-vllm-mlx.sh
# When using 14B/20B, set OPENAI_MODEL in .env to the same value (e.g. mlx-community/Qwen2.5-14B-Instruct-4bit) so Chump uses it.
# If Python/vLLM crashes with Metal OOM but the Mac stays up: we're in good shape. Restart via
#   Chump Menu → Start (8000), or run oven-tender (launchd will auto-restart if scheduled).
#   Defaults are now 4096/0.12 for stability. To try more: VLLM_MAX_TOKENS=8192 VLLM_CACHE_PERCENT=0.15 in .env. Or use 7B model (see above).
# If the Python embed server (port 18765) keeps crashing: use in-process embeddings
#   (cargo build --features inprocess-embed, no CHUMP_EMBED_URL).

set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ -x "$ROOT/scripts/stop-ollama-if-running.sh" ]]; then
  bash "$ROOT/scripts/stop-ollama-if-running.sh" || true
fi

VLLM_MODEL="${VLLM_MODEL:-mlx-community/Qwen2.5-14B-Instruct-4bit}"
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

# Throttle to reduce Metal OOM (Python crashes, Mac stays up). Stable defaults for 14B on 24GB.
# If no crashes for a while, raise in .env: VLLM_MAX_TOKENS=8192 VLLM_CACHE_PERCENT=0.15 (or higher).
VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-1}"
VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
VLLM_CACHE_PERCENT="${VLLM_CACHE_PERCENT:-0.12}"

# vllm-mlx does not support --max-model-len; use a smaller model (e.g. 7B) if OOM.
# VLLM_MAX_MODEL_LEN is kept for doc/compat but not passed to vllm-mlx.
if [[ -n "$VLLM_MAX_MODEL_LEN" ]]; then
  echo "Starting vLLM-MLX: $VLLM_MODEL on port $PORT (VLLM_MAX_MODEL_LEN=$VLLM_MAX_MODEL_LEN not supported by vllm-mlx; use 7B if OOM)"
else
  echo "Starting vLLM-MLX: $VLLM_MODEL on port $PORT (max_num_seqs=$VLLM_MAX_NUM_SEQS, max_tokens=$VLLM_MAX_TOKENS, cache=${VLLM_CACHE_PERCENT})"
fi
exec vllm-mlx serve "$VLLM_MODEL" --port "$PORT" \
  --max-num-seqs "$VLLM_MAX_NUM_SEQS" \
  --max-tokens "$VLLM_MAX_TOKENS" \
  --cache-memory-percent "$VLLM_CACHE_PERCENT"
