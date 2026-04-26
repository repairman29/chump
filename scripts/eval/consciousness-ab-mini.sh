#!/usr/bin/env bash
# Mini A/B: same short prompts with CHUMP_CONSCIOUSNESS_ENABLED=1 vs 0.
# Uses local Ollama qwen2.5:7b (same rules as consciousness-exercise.sh).
# Captures wall time and consciousness-baseline.json copies for comparison.

set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

if curl -s --connect-timeout 2 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
  export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
  export OPENAI_API_KEY="mlx"
  export OPENAI_MODEL="mlx-community/Qwen3-14B-4bit"
elif curl -s --connect-timeout 2 http://127.0.0.1:11434/v1/models >/dev/null 2>&1; then
  export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
  export OPENAI_API_KEY="ollama"
  unset OPENAI_MODEL
  export OPENAI_MODEL="${CHUMP_EXERCISE_MODEL:-qwen2.5:7b}"
else
  echo "ERROR: No model server on :8000 or :11434."
  exit 1
fi

export CHUMP_REPO="$ROOT"
export CHUMP_HOME="$ROOT"
BINARY="./target/release/chump"
[[ -x "$BINARY" ]] || { echo "Build release first: cargo build --release"; exit 1; }

PROMPTS=(
  "Remember that the A/B mini test stores this fact for recall"
  "Calculate 19 + 23"
  "Read the first 5 lines of README.md using read_file if available, else answer from memory"
  "List my current tasks briefly"
)

run_battery() {
  local mode="$1"
  export CHUMP_CONSCIOUSNESS_ENABLED="$mode"
  local i=0
  for p in "${PROMPTS[@]}"; do
    i=$((i + 1))
    echo "  [$mode] prompt $i ..."
    "$BINARY" --chump "$p" >/dev/null 2>&1 || true
  done
}

echo "=== Consciousness A/B mini (4 prompts x2) ==="
echo "Model: $OPENAI_MODEL @ $OPENAI_API_BASE"
echo ""

t0=$(date +%s)
run_battery 1
t1=$(date +%s)
bash "$ROOT/scripts/eval/consciousness-baseline.sh" >/dev/null
cp "$ROOT/logs/consciousness-baseline.json" "$ROOT/logs/baseline-AB-ON.json"
on_sec=$((t1 - t0))

t0=$(date +%s)
run_battery 0
t1=$(date +%s)
bash "$ROOT/scripts/eval/consciousness-baseline.sh" >/dev/null
cp "$ROOT/logs/consciousness-baseline.json" "$ROOT/logs/baseline-AB-OFF.json"
off_sec=$((t1 - t0))

echo ""
echo "Wall time (approx): ON=$on_sec s  OFF=$off_sec s"
echo "Baselines: logs/baseline-AB-ON.json  logs/baseline-AB-OFF.json"
echo "Compare: diff logs/baseline-AB-ON.json logs/baseline-AB-OFF.json"
