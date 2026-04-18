#!/usr/bin/env bash
# run-real-lessons.sh — EVAL-013: Task-specific real lessons A/B harness.
#
# Tests whether task-specific (not generic synthetic) lessons produce a
# larger A/B delta than the generic lessons in EVAL-011/run.sh.
#
# Mode A: seeds the matching lesson for each task into chump_reflections
#         via `chump --seed-ab-lessons`, then runs with CHUMP_REFLECTION_INJECTION=1
# Mode B: clears all seeded lessons, runs with CHUMP_REFLECTION_INJECTION=0
#
# For cloud (API) mode, the harness injects the lesson as a system-prompt
# prefix for mode A using --system-prefix.
#
# Usage:
#   scripts/ab-harness/run-real-lessons.sh [--limit 30] [--judge claude-haiku-4-5]
#
# Prerequisites:
#   - ANTHROPIC_API_KEY set (for cloud mode)
#   - chump binary built for local mode
#
# Output:
#   logs/ab/real-lessons-<unix-ts>.jsonl
#   logs/ab/real-lessons-<unix-ts>.summary.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/real_lessons_tasks.json"
LESSONS_DIR="$SCRIPT_DIR/fixtures/real-lessons"
LIMIT=30
JUDGE="${JUDGE:-claude-haiku-4-5}"
TAG="real-lessons"
TS="$(date +%s)"
OUT="$ROOT/logs/ab/${TAG}-${TS}.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)   LIMIT="$2"; shift 2;;
    --judge)   JUDGE="$2"; shift 2;;
    --tag)     TAG="$2"; shift 2;;
    *)         shift;;
  esac
done

mkdir -p "$ROOT/logs/ab"

echo "[run-real-lessons] EVAL-013: task-specific lessons A/B"
echo "[run-real-lessons] fixture: $FIXTURE"
echo "[run-real-lessons] lessons-dir: $LESSONS_DIR"
echo "[run-real-lessons] limit: $LIMIT"
echo "[run-real-lessons] judge: $JUDGE"
echo ""

# Read all tasks from the fixture.
TASKS=$(python3 -c "
import json, sys
d = json.load(open('$FIXTURE'))
tasks = d['tasks'][:$LIMIT]
print(json.dumps(tasks))
")

TOTAL=$(python3 -c "import json; print(len(json.loads('$TASKS')))")
echo "[run-real-lessons] Running $TOTAL tasks × 2 modes = $((TOTAL * 2)) trials"
echo ""

# Run trials. For each task:
#   Mode A: inject the task's matching lesson as the LESSONS system-prefix block
#   Mode B: no system prefix (baseline)
python3 "$SCRIPT_DIR/run-real-lessons-driver.py" \
    --fixture "$FIXTURE" \
    --lessons-dir "$LESSONS_DIR" \
    --out "$OUT" \
    --limit "$LIMIT" \
    --judge "$JUDGE" \
    --tag "$TAG"

echo ""
echo "[run-real-lessons] done."
echo "[run-real-lessons] output: $OUT"
echo "[run-real-lessons] summary: ${OUT%.jsonl}.summary.json"
