# Max M4 test config: vLLM-MLX on 8000 only, 14B 4-bit, in-process embeddings.
# Requires: cargo build --release --features inprocess-embed and vLLM-MLX serving on port 8000 only (no 8001, no Python embed server).
# Source from repo root: source scripts/env-max_m4.sh

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="http://localhost:8000/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-mlx-community/Qwen2.5-14B-Instruct-4bit}"
export CHUMP_TEST_CONFIG="max_m4"
unset CHUMP_WORKER_API_BASE
unset CHUMP_EMBED_URL
# Throttle: heartbeats use longer intervals and a shared lock so only one round at a time (reduces OOM).
export HEARTBEAT_LOCK="${HEARTBEAT_LOCK:-1}"
