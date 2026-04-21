#!/usr/bin/env bash
# Run chump against vLLM-MLX (port 8000, 14B default).
# Start the server first in another terminal: ./serve-vllm-mlx.sh

export OPENAI_API_BASE=http://localhost:8000/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

exec cargo run -- "$@"
