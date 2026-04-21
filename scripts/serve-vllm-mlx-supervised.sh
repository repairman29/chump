#!/usr/bin/env bash
# Supervised vLLM-MLX wrapper — auto-restarts on Metal crash (INFRA-006).
#
# vllm-mlx crashes when a client disconnects during non-streaming inference:
#   "A command encoder is already encoding to this command buffer"
# The real fix is upstream (waybarrios/vllm-mlx). This wrapper provides
# process-level crash recovery so the server stays healthy across ablation
# sweeps until the upstream patch lands.
#
# Usage:
#   PORT=8000 VLLM_MODEL=mlx-community/Qwen2.5-Coder-14B-Instruct-4bit \
#     ./scripts/serve-vllm-mlx-supervised.sh
#
# Or via the normal serve scripts:
#   VLLM_SUPERVISED=1 ./scripts/serve-vllm-mlx-8001.sh
#
# Env:
#   VLLM_MODEL          (required) HF model ID or local path
#   PORT                (default 8000)
#   VLLM_MAX_SEQS       (default 1)
#   VLLM_MAX_TOKENS     (default 8192)
#   VLLM_CACHE_PERCENT  (default 0.12)
#   RESTART_DELAY_S     (default 3) seconds to wait between crash + restart
#   MAX_RESTARTS        (default 20) stop after this many crash-restarts
#   RESTART_LOG         (default /tmp/vllm-restarts.log)
#
# Exit codes:
#   0  — terminated cleanly via SIGTERM/SIGINT (operator ctrl-c)
#   1  — exceeded MAX_RESTARTS
#   2  — vllm-mlx binary not found

set -euo pipefail

PORT="${PORT:-8000}"
VLLM_MODEL="${VLLM_MODEL:?VLLM_MODEL is required}"
VLLM_MAX_SEQS="${VLLM_MAX_SEQS:-1}"
VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-8192}"
VLLM_CACHE_PERCENT="${VLLM_CACHE_PERCENT:-0.12}"
RESTART_DELAY_S="${RESTART_DELAY_S:-3}"
MAX_RESTARTS="${MAX_RESTARTS:-20}"
RESTART_LOG="${RESTART_LOG:-/tmp/vllm-restarts.log}"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v vllm-mlx &>/dev/null; then
  echo "[supervised] ERROR: vllm-mlx not found. Install with:" >&2
  echo "  uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'" >&2
  exit 2
fi

CHILD_PID=""
RESTART_COUNT=0
CLEAN_EXIT=0

_cleanup() {
  CLEAN_EXIT=1
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    echo "[supervised] Forwarding SIGTERM to vllm-mlx (pid=$CHILD_PID)…"
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  echo "[supervised] Exiting cleanly." | tee -a "$RESTART_LOG"
  exit 0
}
trap _cleanup SIGINT SIGTERM

echo "[supervised] Starting supervised vllm-mlx: $VLLM_MODEL on port $PORT" | tee -a "$RESTART_LOG"
echo "[supervised] Max restarts: $MAX_RESTARTS  Log: $RESTART_LOG" | tee -a "$RESTART_LOG"

while true; do
  START_TS=$(date +%s)

  vllm-mlx serve "$VLLM_MODEL" \
    --port "$PORT" \
    --max-num-seqs "$VLLM_MAX_SEQS" \
    --max-tokens "$VLLM_MAX_TOKENS" \
    --cache-memory-percent "$VLLM_CACHE_PERCENT" &
  CHILD_PID=$!

  wait "$CHILD_PID" 2>/dev/null
  EXIT_CODE=$?
  CHILD_PID=""

  [[ "$CLEAN_EXIT" == "1" ]] && exit 0

  UPTIME=$(( $(date +%s) - START_TS ))
  RESTART_COUNT=$(( RESTART_COUNT + 1 ))
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "[$TS][supervised] vllm-mlx exited cleanly (code=0). Stopping supervisor." | tee -a "$RESTART_LOG"
    exit 0
  fi

  echo "[$TS][supervised] vllm-mlx crashed (code=$EXIT_CODE, uptime=${UPTIME}s, restart #$RESTART_COUNT/$MAX_RESTARTS)" | tee -a "$RESTART_LOG"

  if (( RESTART_COUNT >= MAX_RESTARTS )); then
    echo "[$TS][supervised] Exceeded MAX_RESTARTS ($MAX_RESTARTS). Giving up." | tee -a "$RESTART_LOG"
    exit 1
  fi

  echo "[$TS][supervised] Waiting ${RESTART_DELAY_S}s before restart…" | tee -a "$RESTART_LOG"
  sleep "$RESTART_DELAY_S"
done
