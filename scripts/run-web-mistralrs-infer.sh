#!/usr/bin/env bash
# Start Chump web with in-process mistral.rs (CPU) as primary, without editing .env.
# Requires: cargo build --release --features mistralrs-infer -p rust-agent
# For Apple Silicon GPU instead, install full Xcode CLT so `xcrun metal` works, then:
#   cargo build --release --features mistralrs-metal -p rust-agent
# and set CHUMP_MISTRALRS_FORCE_CPU=0 (default).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ ! -x ./target/release/chump ]]; then
  echo "Missing ./target/release/chump — build: cargo build --release --features mistralrs-infer -p rust-agent" >&2
  exit 1
fi
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi
export CHUMP_INFERENCE_BACKEND=mistralrs
export CHUMP_MISTRALRS_MODEL="${CHUMP_MISTRALRS_MODEL:-Qwen/Qwen3-4B}"
export OPENAI_MODEL="${OPENAI_MODEL:-$CHUMP_MISTRALRS_MODEL}"
# Perceived latency: SSE text_delta on PWA /api/chat (see docs/MISTRALRS_AGENT_POWER_PATH.md §5)
export CHUMP_MISTRALRS_STREAM_TEXT_DELTAS="${CHUMP_MISTRALRS_STREAM_TEXT_DELTAS:-1}"
# Primary in-process: do not point at vLLM/Ollama for chat.
unset OPENAI_API_BASE
PORT="${CHUMP_WEB_PORT:-3000}"
if [[ "$1" == "--port" ]] && [[ -n "${2:-}" ]]; then
  PORT="$2"
  shift 2
fi
exec ./target/release/chump --web --port "$PORT" "$@"
