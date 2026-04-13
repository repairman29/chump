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
# After .env: optional one-shot Ollama golden path (ignores OPENAI_* from .env for this process).
if [[ "${CHUMP_GOLDEN_PATH_OLLAMA:-}" == "1" ]]; then
  export OPENAI_API_BASE="http://localhost:11434/v1"
  export OPENAI_API_KEY="ollama"
  export OPENAI_MODEL="qwen2.5:14b"
fi
# So run_cli can find Cursor CLI (installer puts it in ~/.local/bin on darwin)
export PATH="$HOME/.local/bin:$HOME/.cursor/bin:$PATH"
mkdir -p logs
# Docs often write `./run-local.sh -- --check-config`; strip a stray leading `--` so chump sees `--check-config` as argv[1].
if [[ "${1:-}" == "--" ]]; then
  shift
fi
# Golden-path / CI: `CHUMP_USE_RELEASE=1 ./run-local.sh --check-config` uses the release binary (after `cargo build --release --bin chump`).
if [[ "${CHUMP_USE_RELEASE:-}" == "1" ]]; then
  exec cargo run --release --bin chump -- "$@"
fi
exec cargo run --bin chump -- "$@"
