#!/usr/bin/env bash
# Autonomous MLX + Vector 7 smoke: MLX server (vllm-mlx) + Chump CLI with CHUMP_CLUSTER_MODE=1.
# Routing: vLLM-MLX typically binds 8000 (a second model can use 8001 via PORT=8001 in serve-vllm-mlx.sh).
# Ollama’s OpenAI shim is usually http://localhost:11434/v1 (often CPU); this script forces MLX on 8000
# so OPENAI_API_BASE from .env cannot send the smoke to Ollama by mistake.
# Uses --chump so ChumpAgent, tools, and SwarmExecutor are active (bare cargo message uses axonerai Agent only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p logs

MLX_PID=""
cleanup() {
  if [[ -n "${MLX_PID}" ]] && kill -0 "${MLX_PID}" 2>/dev/null; then
    kill "${MLX_PID}" 2>/dev/null || true
    wait "${MLX_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -f .env ]]; then set -a; source .env; set +a; fi

echo "[mlx-smoke] starting MLX server (logs/mlx-smoke-server.log)..."
./serve-vllm-mlx.sh > logs/mlx-smoke-server.log 2>&1 &
MLX_PID=$!

echo "[mlx-smoke] waiting 45s for model load..."
sleep 45

# Smoke must hit this process’s vLLM-MLX bind (do not inherit Ollama/other bases from .env).
export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
export CHUMP_CLUSTER_MODE=1
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
# Many OpenAI-compatible MLX stacks expect a placeholder key.
export OPENAI_API_KEY="${OPENAI_API_KEY:-mlx-local-dummy}"
export RUST_LOG="${RUST_LOG:-info,rust_agent::task_executor=info,rust_agent::agent_loop=info}"

PROMPT='Use the task tool to list all open tasks, then write a 1-sentence summary of my current priorities.'

echo "[mlx-smoke] running Chump (--chump) with OPENAI_API_BASE=${OPENAI_API_BASE} CHUMP_CLUSTER_MODE=${CHUMP_CLUSTER_MODE}"
set +e
cargo run --bin chump -- --chump "${PROMPT}" > logs/mlx-smoke-client.log 2>&1
CHUMP_RC=$?
set -e
echo "[mlx-smoke] chump exit code=${CHUMP_RC}"

cleanup
trap - EXIT
MLX_PID=""
echo "[mlx-smoke] done."
