#!/usr/bin/env bash
# run-cognition-ab.sh — EVAL-101: cognition stack A/B/C comparison.
#
# Runs the reflection_tasks.json fixture under 3 conditions:
#   A: cognition stack OFF (baseline)
#   B: cognition stack ON (treatment)
#   C: control (OFF + 500-token neutral padding to rule out length confound)
#
# Each cell runs the harness once. The harness runs every task twice
# (mode A=mode 1, mode B=mode 0 of a meaningless dummy flag), so each
# cell produces 2×N_PER_CELL trials. This gives n≈40/cell with N_PER_CELL=20,
# which exceeds the preregistered n=20 — strictly more power.
#
# Usage:
#   scripts/eval/run-cognition-ab.sh [--smoke] [--skip-score]
#
# Env:
#   CHUMP_BIN       — path to chump binary (default: ./target/release/chump)
#   OPENAI_API_BASE — default auto-detected (ollama :11434 → mlx :8000)
#   OPENAI_MODEL    — default qwen2.5:7b (ollama) or Qwen3-14B-4bit (mlx)
#   N_PER_CELL      — tasks per cell (default 20, --smoke uses 3)
#   OUT_DIR         — output directory (default logs/ab/)
#
# Preregistration: docs/eval/preregistered/EVAL-101.md

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/release/chump}"
SMOKE=0
SKIP_SCORE=0
N_PER_CELL="${N_PER_CELL:-20}"
OUT_DIR="${OUT_DIR:-logs/ab}"

FIXTURE="$REPO_ROOT/scripts/ab-harness/fixtures/reflection_tasks.json"
PADDED_FIXTURE="$REPO_ROOT/scripts/eval/fixtures/reflection_tasks_padded.json"
HARNESS="$REPO_ROOT/scripts/ab-harness/run.sh"
SCORER="$REPO_ROOT/scripts/ab-harness/score.py"

while [[ $# -gt 0 ]]; do
  case "$1" in --smoke) SMOKE=1; shift ;; --skip-score) SKIP_SCORE=1; shift ;; *) echo "unknown: $1" >&2; exit 2 ;; esac
done
if [[ "$SMOKE" -eq 1 ]]; then N_PER_CELL=3; fi

preflight() {
  local errors=0
  if [[ ! -x "$CHUMP_BIN" ]]; then echo "ERROR: $CHUMP_BIN not found. Build: cargo build --release --bin chump" >&2; errors=1; fi
  if [[ ! -f "$FIXTURE" ]]; then echo "ERROR: fixture not found: $FIXTURE" >&2; errors=1; fi
  if [[ ! -x "$HARNESS" ]]; then echo "ERROR: harness not found: $HARNESS" >&2; errors=1; fi
  if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq required" >&2; errors=1; fi
  if [[ "$SKIP_SCORE" -eq 0 && ! -f "$SCORER" ]]; then echo "ERROR: scorer not found: $SCORER" >&2; errors=1; fi

  # Check provider is reachable
  local probe=0
  if curl -sf --connect-timeout 2 "${OPENAI_API_BASE:-http://127.0.0.1:11434/v1}/models" >/dev/null 2>&1; then
    probe=1
  fi
  if [[ "$probe" -eq 0 ]]; then
    echo "WARNING: No LLM endpoint reachable at OPENAI_API_BASE=${OPENAI_API_BASE:-not set}"
    echo "  Set OPENAI_API_BASE before running, or start Ollama/MLX."
    echo "  Continuing anyway (harness has its own probe)."
  fi

  if [[ "$errors" -ne 0 ]]; then exit 2; fi
  echo "[preflight] OK — chump=$CHUMP_BIN fixture=$FIXTURE n=$N_PER_CELL/cell"
}

mkdir -p "$OUT_DIR"
TS=$(date +%s)
TAG="cognition-ab-${TS}"

run_cell() {
  local cell="$1" label="$2"
  echo ""
  echo "=== Cell $cell ($label) ==="
  echo "  flags: CHUMP_REFLECTION_INJECTION=${CHUMP_REFLECTION_INJECTION:-0} CHUMP_NEUROMOD_ENABLED=${CHUMP_NEUROMOD_ENABLED:-0} CHUMP_LESSONS_SEMANTIC=${CHUMP_LESSONS_SEMANTIC:-0}"
  echo "  N=$N_PER_CELL tasks × 2 modes = $((N_PER_CELL * 2)) trials"
  echo ""

  bash "$HARNESS" \
    --fixture "${1}" \
    --flag CHUMP_COGNITION_AB_DUMMY \
    --tag "${TAG}-${cell}" \
    --limit "$N_PER_CELL" \
    --chump-bin "$CHUMP_BIN"
}

# Cell A: cognition OFF
echo "[cognition-ab] Cell A: cognition stack OFF"
export CHUMP_REFLECTION_INJECTION=0 CHUMP_NEUROMOD_ENABLED=0 CHUMP_LESSONS_SEMANTIC=0
CELL_A_LOG="$OUT_DIR/${TAG}-A.jsonl"
run_cell "$FIXTURE" "A"
# The harness writes to a timestamped file; find it
find "$OUT_DIR" -name "${TAG}-A-*.jsonl" -not -name "*.summary.*" 2>/dev/null | head -1 > /tmp/cell_a_log_path

# Cell B: cognition ON
echo "[cognition-ab] Cell B: cognition stack ON"
export CHUMP_REFLECTION_INJECTION=1 CHUMP_NEUROMOD_ENABLED=1 CHUMP_LESSONS_SEMANTIC=1
run_cell "$FIXTURE" "B"
find "$OUT_DIR" -name "${TAG}-B-*.jsonl" -not -name "*.summary.*" 2>/dev/null | head -1 > /tmp/cell_b_log_path

# Cell C: control (OFF + padded fixture)
echo "[cognition-ab] Cell C: cognition OFF + 500-token neutral padding"
export CHUMP_REFLECTION_INJECTION=0 CHUMP_NEUROMOD_ENABLED=0 CHUMP_LESSONS_SEMANTIC=0
if [[ -f "$PADDED_FIXTURE" ]]; then
  run_cell "$PADDED_FIXTURE" "C"
  find "$OUT_DIR" -name "${TAG}-C-*.jsonl" -not -name "*.summary.*" 2>/dev/null | head -1 > /tmp/cell_c_log_path
else
  echo "  WARNING: padded fixture not found at $PADDED_FIXTURE — skipping Cell C"
  echo "  Generate it: scripts/eval/generate-padded-fixture.sh"
  echo "" > /tmp/cell_c_log_path
fi

# Score
if [[ "$SKIP_SCORE" -eq 0 && -f "$SCORER" ]]; then
  echo ""
  echo "=== Scoring ==="
  for cell in A B C; do
    log=$(cat /tmp/cell_${cell}_log_path 2>/dev/null || true)
    if [[ -n "$log" && -f "$log" ]]; then
      echo "Scoring Cell $cell: $log"
      python3 "$SCORER" "$log" "$FIXTURE" 2>&1 || echo "  (scoring failed — continuing)"
    fi
  done
fi

echo ""
echo "[cognition-ab] Done."
echo "  Tag: $TAG"
echo "  Trials: $OUT_DIR/${TAG}-*.jsonl"
echo ""
echo "To analyze results:"
echo "  scripts/ab-harness/score.py \$TRIALS_FILE $FIXTURE"
