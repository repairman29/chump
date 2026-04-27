# Default test config: Ollama on 11434. Source from repo root: source scripts/dev/env-default.sh
# Use with run-tests-with-config.sh or before running battle-qa, run-autonomy-tests, etc.

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
export CHUMP_TEST_CONFIG="${CHUMP_TEST_CONFIG:-default}"
