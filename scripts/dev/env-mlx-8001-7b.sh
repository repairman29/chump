# Lite MLX on 8001 (7B) — source from repo root before `cargo run` / `./run-web.sh`:
#   source scripts/dev/env-mlx-8001-7b.sh
# Requires: vLLM-MLX on port 8001 (`./scripts/setup/serve-vllm-mlx-8001.sh` or `restart-vllm-8001-if-down.sh`).
# See docs/operations/INFERENCE_PROFILES.md §1a.

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

export OPENAI_API_BASE="http://127.0.0.1:8001/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
unset CHUMP_WORKER_API_BASE
unset CHUMP_EMBED_URL
