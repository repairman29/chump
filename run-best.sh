#!/usr/bin/env bash
# [DEPRECATED — INFRA-691] Use './run.sh best' instead. This shim will be removed in a future release.
# Run chump against vLLM-MLX (port 8000, 14B default).
# Start the server first in another terminal: ./serve-vllm-mlx.sh
echo "[DEPRECATED] run-best.sh: use './run.sh best' instead" >&2

export OPENAI_API_BASE=http://localhost:8000/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

exec cargo run -- "$@"
