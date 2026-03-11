#!/usr/bin/env bash
# Run Chump against local Ollama (no paid API, no Python in agent runtime).
# Requires: Ollama installed and running; pull Qwen 2.5 14B: ollama serve && ollama pull qwen2.5:14b
# Run from repo root, or by path: /path/to/chump-repo/run-local.sh

set -e
cd "$(dirname "$0")"
export CHUMP_HOME="${CHUMP_HOME:-$(pwd)}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
mkdir -p logs
exec cargo run -- "$@"
