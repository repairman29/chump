#!/usr/bin/env bash
# Run the Chump Web PWA. Ensures the model server is up when .env points at 8000, then starts the web server.
# Usage: ./run-web.sh [--port 3000]
# Set CHUMP_HOME (or run from repo root) so web/ and logs are found. Optional: CHUMP_WEB_PORT=3001

set -e
cd "$(dirname "$0")"
export CHUMP_HOME="${CHUMP_HOME:-$(pwd)}"
export CHUMP_REPO="${CHUMP_REPO:-$CHUMP_HOME}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
export CHUMP_REPO="${CHUMP_REPO:-$CHUMP_HOME}"

# When using 8000, ensure vLLM is up before starting (same as run-discord-full.sh).
if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] || [[ "${OPENAI_API_BASE:-}" == *"localhost:8000"* ]]; then
  if [[ -x "$CHUMP_HOME/scripts/restart-vllm-if-down.sh" ]]; then
    echo "Ensuring model server (8000) is up..."
    "$CHUMP_HOME/scripts/restart-vllm-if-down.sh" || true
  fi
fi

mkdir -p logs
PORT="${CHUMP_WEB_PORT:-3000}"
if [[ "$1" == "--port" ]] && [[ -n "${2:-}" ]]; then
  PORT="$2"
  shift 2
fi
if [[ -x ./target/release/rust-agent ]]; then
  exec ./target/release/rust-agent --web --port "$PORT" "$@"
elif [[ -x ./target/debug/rust-agent ]]; then
  exec ./target/debug/rust-agent --web --port "$PORT" "$@"
fi
exec cargo run -- --web --port "$PORT" "$@"
