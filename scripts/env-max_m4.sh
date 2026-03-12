# Max M4 test config: vLLM-MLX on 8000 only, 30B 4-bit DWQ, in-process embeddings.
# Requires: cargo build --release --features inprocess-embed and vLLM-MLX serving on port 8000 only (no 8001, no Python embed server).
# Source from repo root: source scripts/env-max_m4.sh

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="http://localhost:8000/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-mlx-community/Qwen3-30B-A3B-4bit-DWQ}"
export CHUMP_TEST_CONFIG="max_m4"
unset CHUMP_WORKER_API_BASE
unset CHUMP_EMBED_URL
