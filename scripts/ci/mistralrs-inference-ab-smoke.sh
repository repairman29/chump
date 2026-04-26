#!/usr/bin/env bash
# A/B smoke: same fixed CLI prompt across HTTP vs in-process mistral.
# Full methodology: docs/MISTRALRS_AGENT_POWER_PATH.md
#
# Usage:
#   ./scripts/ci/mistralrs-inference-ab-smoke.sh print          # print env recipes (modes A/B/C)
#   ./scripts/ci/mistralrs-inference-ab-smoke.sh http           # AB-2 with OPENAI_API_BASE from .env
#   ./scripts/ci/mistralrs-inference-ab-smoke.sh inproc         # AB-2 with mistral primary (unset OPENAI_API_BASE)
#
# Env:
#   CHUMP_AB_PROMPT   — override default one-line smoke prompt
#   CHUMP_AB_BINARY   — path to chump (default ./target/release/chump)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEFAULT_PROMPT='Reply with exactly one line of text: AB_SMOKE_OK'
PROMPT="${CHUMP_AB_PROMPT:-$DEFAULT_PROMPT}"
BIN="${CHUMP_AB_BINARY:-$ROOT/target/release/chump}"

if [[ ! -x "$BIN" ]]; then
  echo "Missing executable: $BIN" >&2
  echo "Build: cargo build --release -p chump" >&2
  echo "In-process mode also needs: --features mistralrs-metal (Apple Silicon) or mistralrs-infer" >&2
  exit 1
fi

print_recipes() {
  cat <<'EOF'
=== Mode A/B: HTTP primary (vLLM-MLX, Ollama, or mistralrs serve) ===
  source .env   # or set explicitly
  export OPENAI_API_BASE=http://127.0.0.1:8000/v1   # example
  export OPENAI_MODEL=...                           # must match server
  unset CHUMP_INFERENCE_BACKEND
  unset CHUMP_MISTRALRS_MODEL
  ./scripts/ci/mistralrs-inference-ab-smoke.sh http

=== Mode C: In-process mistral.rs ===
  cargo build --release --features mistralrs-metal -p chump   # or mistralrs-infer
  export CHUMP_INFERENCE_BACKEND=mistralrs
  export CHUMP_MISTRALRS_MODEL=Qwen/Qwen3-4B    # example
  unset OPENAI_API_BASE
  ./scripts/ci/mistralrs-inference-ab-smoke.sh inproc

Micro-bench (in-process only): ./scripts/eval/bench-mistralrs-chump.sh --help
Battle QA smoke: BATTLE_QA_MAX=20 ./scripts/ci/battle-qa.sh
EOF
}

MODE="${1:-}"
case "$MODE" in
  print|"")
    print_recipes
    ;;
  http)
    if [[ -f .env ]]; then
      set -a
      # shellcheck source=/dev/null
      source .env
      set +a
    fi
    if [[ -z "${OPENAI_API_BASE:-}" ]]; then
      echo "OPENAI_API_BASE is unset. Load .env or export it (Mode A/B)." >&2
      exit 1
    fi
    unset CHUMP_INFERENCE_BACKEND
    echo "==> AB-2 http: OPENAI_API_BASE=$OPENAI_API_BASE OPENAI_MODEL=${OPENAI_MODEL:-}" >&2
    echo "==> Prompt (first 80 chars): ${PROMPT:0:80}..." >&2
    time "$BIN" --chump "$PROMPT"
    ;;
  inproc)
    if [[ -f .env ]]; then
      set -a
      # shellcheck source=/dev/null
      source .env
      set +a
    fi
    export CHUMP_INFERENCE_BACKEND=mistralrs
    export CHUMP_MISTRALRS_MODEL="${CHUMP_MISTRALRS_MODEL:-Qwen/Qwen3-4B}"
    unset OPENAI_API_BASE
    echo "==> AB-2 inproc: CHUMP_MISTRALRS_MODEL=$CHUMP_MISTRALRS_MODEL" >&2
    echo "==> Prompt (first 80 chars): ${PROMPT:0:80}..." >&2
    time "$BIN" --chump "$PROMPT"
    ;;
  *)
    echo "usage: $0 print|http|inproc" >&2
    exit 1
    ;;
esac
