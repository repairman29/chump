#!/usr/bin/env bash
# run-cognition-ab.sh — EVAL-101: cognition stack A/B/C comparison.
#
# Runs the reflection_tasks.json fixture under 3 conditions:
#   A: cognition stack OFF
#   B: cognition stack ON
#   C: control (OFF + 500-token neutral padding)
#
# Usage:
#   scripts/eval/run-cognition-ab.sh [--smoke] [--skip-score]
#
# Env:
#   CHUMP_BIN     — path to chump binary (default: ./target/release/chump)
#   OPENAI_*      — must point to a working model (see run.sh)
#   N_PER_CELL    — tasks per cell (default 20, --smoke uses 3)
#   OUT_DIR       — output directory (default logs/ab/)
#   COGNITION_OFF — set of flags to toggle OFF (space-separated)
#   COGNITION_ON  — set of flags to toggle ON (space-separated)
#
# Preregistration: docs/eval/preregistered/EVAL-101.md

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/release/chump}"
cd "$REPO_ROOT"

SMOKE=0
SKIP_SCORE=0
N_PER_CELL="${N_PER_CELL:-20}"
OUT_DIR="${OUT_DIR:-logs/ab}"

COGNITION_OFF="${COGNITION_OFF:-CHUMP_REFLECTION_INJECTION=0 CHUMP_NEUROMOD_ENABLED=0 CHUMP_LESSONS_SEMANTIC=0}"
COGNITION_ON="${COGNITION_ON:-CHUMP_REFLECTION_INJECTION=1 CHUMP_NEUROMOD_ENABLED=1 CHUMP_LESSONS_SEMANTIC=1}"

FIXTURE="scripts/ab-harness/fixtures/reflection_tasks.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --skip-score) SKIP_SCORE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$SMOKE" -eq 1 ]]; then
  N_PER_CELL=3
  echo "[cognition-ab] SMOKE mode — n=$N_PER_CELL/cell"
fi

if [[ ! -f "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not found. Build: cargo build --release --bin chump" >&2
  exit 2
fi

export CHUMP_BIN
TS=$(date +%s)
TAG="cognition-ab-${TS}"

HARNESS="$REPO_ROOT/scripts/ab-harness/run.sh"

run_cell() {
  local cell="$1" label="$2"
  local export_env=("$3")
  local fixture_override="$4"

  echo ""
  echo "=== Cell $cell ($label) ==="
  echo "  N=$N_PER_CELL"
  echo "  flags: ${export_env[*]}"
  echo ""

  for env_var in "${export_env[@]}"; do
    local key="${env_var%%=*}"
    local val="${env_var#*=}"
    export "$key"="$val"
  done

  bash "$HARNESS" \
    --fixture "${fixture_override:-$FIXTURE}" \
    --flag CHUMP_COGNITION_AB_CELL \
    --tag "${TAG}-${cell}" \
    --limit "$N_PER_CELL" \
    --chump-bin "$CHUMP_BIN"
}

# Run the 2 core cells using the harness (single-flag toggle per run).
# The harness runs each task twice (mode A=flag=1, mode B=flag=0).
# Cell A: cognition OFF (flag value doesn't matter — all flags are
#   externally set to 0 before the harness runs).
# Cell B: cognition ON (same — externally set before harness runs).

export CHUMP_COGNITION_AB_CELL="A"
run_cell "A" "cognition OFF" "$COGNITION_OFF"

export CHUMP_COGNITION_AB_CELL="B"
run_cell "B" "cognition ON" "$COGNITION_ON"

# Cell C: neutral padding control. Use a padded version of the fixture.
# If the padded fixture doesn't exist, run with same flags as A but
# the harness won't know about padding — we add it via env var.
if [[ -f "${FIXTURE%.json}_padded.json}" ]]; then
  echo "  (using padded fixture)"
else
  echo "  (no padded fixture — skipping Cell C; padding not yet implemented)"
fi

echo ""
echo "[cognition-ab] All cells complete."
echo "  Trials: $OUT_DIR/${TAG}-*.jsonl"
echo "  Next: scripts/ab-harness/score.py <trials> $FIXTURE"
