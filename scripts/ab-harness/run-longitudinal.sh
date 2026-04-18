#!/usr/bin/env bash
# run-longitudinal.sh — EVAL-021: Longitudinal accumulation A/B harness.
#
# Tests whether accumulated session memory (COG-015 blackboard + EVAL-013 lessons)
# leads to measurably better performance as the number of prior sessions grows.
#
# Design:
#   - 5 checkpoints: 10, 25, 50, 75, 100 sessions of accumulated project context
#   - Mode A (CHUMP_ENTITY_PREFETCH=1): injects accumulated facts from sessions 1..C
#     into the system prompt for each held-out evaluation task.
#   - Mode B: no accumulated context — fresh session.
#   - 20 held-out tasks span the full 100-session range; tasks become "in scope"
#     (answerable) as the checkpoint increases.
#
# Expected result: mode A's pass rate grows with checkpoint (monotone delta curve).
# Mode B's pass rate stays near zero (no context to answer from).
#
# Usage:
#   scripts/ab-harness/run-longitudinal.sh [--checkpoints 10,25,50,75,100]
#                                           [--judge claude-haiku-4-5]
#                                           [--model claude-haiku-4-5]
#
# Output:
#   logs/ab/longitudinal-<unix-ts>.jsonl
#   logs/ab/longitudinal-<unix-ts>.summary.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/longitudinal_trace.json"
JUDGE="${JUDGE:-claude-haiku-4-5}"
MODEL="${MODEL:-claude-haiku-4-5}"
CHECKPOINTS="${CHECKPOINTS:-10,25,50,75,100}"
TAG="longitudinal"
TS="$(date +%s)"
OUT="$ROOT/logs/ab/${TAG}-${TS}.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkpoints) CHECKPOINTS="$2"; shift 2;;
    --judge)       JUDGE="$2";       shift 2;;
    --model)       MODEL="$2";       shift 2;;
    --tag)         TAG="$2";         shift 2;;
    *)             shift;;
  esac
done

mkdir -p "$ROOT/logs/ab"

echo "[run-longitudinal] EVAL-021: longitudinal accumulation A/B"
echo "[run-longitudinal] fixture:     $FIXTURE"
echo "[run-longitudinal] checkpoints: $CHECKPOINTS"
echo "[run-longitudinal] judge:       $JUDGE"
echo "[run-longitudinal] model:       $MODEL"
echo ""

python3 "$SCRIPT_DIR/run-longitudinal-driver.py" \
    --fixture     "$FIXTURE" \
    --out         "$OUT" \
    --judge       "$JUDGE" \
    --model       "$MODEL" \
    --checkpoints "$CHECKPOINTS" \
    --tag         "$TAG"

echo ""
echo "[run-longitudinal] done."
echo "[run-longitudinal] output:  $OUT"
echo "[run-longitudinal] summary: ${OUT%.jsonl}.summary.json"
