#!/usr/bin/env bash
# Run rust-agent against vLLM-MLX (best setup per plan: port 8000, 30B DWQ).
# Start the server first in another terminal: ./serve-vllm-mlx.sh

export OPENAI_API_BASE=http://localhost:8000/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

exec cargo run -- "$@"
