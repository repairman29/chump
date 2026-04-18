#!/usr/bin/env bash
# run-cross-session.sh — EVAL-019: Cross-session continuity A/B harness.
#
# Tests whether the entity-keyed blackboard prefetch (COG-015) enables
# a fresh session to resume context established in a prior session.
#
# Design:
#   - 20 pair-tasks: each has a "session 1" context fact and a "session 2"
#     follow-up prompt that mentions entities from that fact.
#   - Mode A (CHUMP_ENTITY_PREFETCH=1): blackboard is seeded with session-1
#     facts; entity prefetch injects the matching fact into context.
#   - Mode B (CHUMP_ENTITY_PREFETCH=0): no blackboard injection; the
#     fresh session has no memory of session 1.
#
# Scoring: does the session-2 response engage with the specific context
# from session 1 (mentions project names, tech choices, decisions)?
#
# Usage:
#   scripts/ab-harness/run-cross-session.sh [--limit 20] [--judge claude-haiku-4-5] [--db-path sessions/chump_memory.db]
#
# Output:
#   logs/ab/cross-session-<unix-ts>.jsonl
#   logs/ab/cross-session-<unix-ts>.summary.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/cross_session_tasks.json"
SEED_SQL="$SCRIPT_DIR/fixtures/cross_session_seeds.sql"
LIMIT=20
JUDGE="${JUDGE:-claude-haiku-4-5}"
MODEL="${MODEL:-claude-haiku-4-5}"
DB_PATH="${DB_PATH:-$ROOT/sessions/chump_memory.db}"
TAG="cross-session"
TS="$(date +%s)"
OUT="$ROOT/logs/ab/${TAG}-${TS}.jsonl"
SKIP_SEED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)     LIMIT="$2";    shift 2;;
    --judge)     JUDGE="$2";    shift 2;;
    --model)     MODEL="$2";    shift 2;;
    --db-path)   DB_PATH="$2";  shift 2;;
    --skip-seed) SKIP_SEED=1;   shift;;
    --tag)       TAG="$2";      shift 2;;
    *)           shift;;
  esac
done

mkdir -p "$ROOT/logs/ab"

echo "[run-cross-session] EVAL-019: cross-session continuity A/B"
echo "[run-cross-session] fixture: $FIXTURE"
echo "[run-cross-session] db-path: $DB_PATH"
echo "[run-cross-session] limit:   $LIMIT"
echo "[run-cross-session] judge:   $JUDGE"
echo "[run-cross-session] model:   $MODEL"
echo ""

# Seed session-1 context facts into blackboard_persist for Mode A.
if [[ "$SKIP_SEED" -eq 0 ]]; then
    if [[ ! -f "$DB_PATH" ]]; then
        echo "[run-cross-session] WARNING: DB not found at $DB_PATH — running without seeding."
        echo "[run-cross-session] Mode A will behave like Mode B (no blackboard facts)."
    else
        echo "[run-cross-session] Seeding session-1 context facts into blackboard_persist…"
        sqlite3 "$DB_PATH" < "$SEED_SQL"
        echo "[run-cross-session] Seeded OK."
    fi
    echo ""
fi

# Run the cross-session A/B driver.
python3 "$SCRIPT_DIR/run-cross-session-driver.py" \
    --fixture "$FIXTURE" \
    --out     "$OUT" \
    --limit   "$LIMIT" \
    --judge   "$JUDGE" \
    --model   "$MODEL" \
    --tag     "$TAG"

echo ""
echo "[run-cross-session] done."
echo "[run-cross-session] output:  $OUT"
echo "[run-cross-session] summary: ${OUT%.jsonl}.summary.json"
