#!/usr/bin/env bash
# Pre-download the Chump-recommended MLX model mix so they're cached for later use.
# Runs one model at a time on port 8000: start server, wait for ready, then stop.
# No need for multiple ports during download. First run per model can take several minutes (download + load).
#
# After this, run servers with: ./serve-vllm-mlx.sh (30B on 8000), ./scripts/serve-vllm-mlx-8001.sh (7B on 8001), etc.
# One port per model when running at the same time — see docs/MLX_MULTI_MODEL.md.

set -e
cd "$(dirname "$0")/.."
export PATH="${HOME}/.local/bin:${PATH}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"

PORT=8000
TIMEOUT="${DOWNLOAD_TIMEOUT:-600}"

# Chump mix: main (30B), worker/fast (7B), small (3B). Override with space-separated env:
# CHUMP_MLX_MODELS="mlx-community/Qwen2.5-7B-Instruct-4bit" ./scripts/download-mlx-models.sh
MODELS=(${CHUMP_MLX_MODELS:-mlx-community/Qwen3-30B-A3B-4bit-DWQ mlx-community/Qwen2.5-7B-Instruct-4bit mlx-community/Qwen2.5-3B-Instruct-4bit})

if ! command -v vllm-mlx &>/dev/null; then
  echo "vllm-mlx not found. Install with: uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'"
  exit 1
fi

ready() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true
}

for model in "${MODELS[@]}"; do
  echo "=============================================="
  echo "Downloading/loading: $model (port $PORT, timeout ${TIMEOUT}s)"
  echo "=============================================="
  vllm-mlx serve "$model" --port "$PORT" &
  pid=$!
  trap "kill $pid 2>/dev/null; wait $pid 2>/dev/null; exit 130" INT TERM
  deadline=$(($(date +%s) + TIMEOUT))
  got_ready=0
  while [[ $(date +%s) -lt $deadline ]]; do
    if [[ "$(ready)" == "200" ]]; then
      echo "Ready: $model"
      got_ready=1
      break
    fi
    sleep 5
  done
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  trap - INT TERM
  if [[ $got_ready -ne 1 ]]; then
    echo "Timeout waiting for $model" >&2
    exit 1
  fi
  sleep 2
done

echo "Done. All models cached. Start servers with: ./serve-vllm-mlx.sh (8000), ./scripts/serve-vllm-mlx-8001.sh (8001), etc."
