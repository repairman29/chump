#!/usr/bin/env bash
# run-memory-recall.sh — EVAL-018: Memory recall A/B harness.
#
# Tests whether the entity-keyed blackboard prefetch (COG-015) helps the
# agent surface project-specific facts stored in chump_blackboard_persist.
#
# Mode A: CHUMP_ENTITY_PREFETCH=1  (entity-keyed facts injected from DB)
# Mode B: CHUMP_ENTITY_PREFETCH=0  (no blackboard injection)
#
# Before running, seed the memory:
#   sqlite3 sessions/chump_memory.db < scripts/ab-harness/fixtures/memory_seeds.sql
#
# Usage:
#   scripts/ab-harness/run-memory-recall.sh [--limit 30] [--judge claude-haiku-4-5] [--db-path sessions/chump_memory.db]
#
# Output:
#   logs/ab/memory-recall-<unix-ts>.jsonl
#   logs/ab/memory-recall-<unix-ts>.summary.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/memory_recall_tasks.json"
SEED_SQL="$SCRIPT_DIR/fixtures/memory_seeds.sql"
LIMIT=30
JUDGE="${JUDGE:-claude-haiku-4-5}"
DB_PATH="${DB_PATH:-$ROOT/sessions/chump_memory.db}"
TAG="memory-recall"
TS="$(date +%s)"
OUT="$ROOT/logs/ab/${TAG}-${TS}.jsonl"
SKIP_SEED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)     LIMIT="$2"; shift 2;;
    --judge)     JUDGE="$2"; shift 2;;
    --db-path)   DB_PATH="$2"; shift 2;;
    --skip-seed) SKIP_SEED=1; shift;;
    --tag)       TAG="$2"; shift 2;;
    *)           shift;;
  esac
done

mkdir -p "$ROOT/logs/ab"

echo "[run-memory-recall] EVAL-018: memory recall A/B"
echo "[run-memory-recall] fixture:  $FIXTURE"
echo "[run-memory-recall] db-path:  $DB_PATH"
echo "[run-memory-recall] limit:    $LIMIT"
echo "[run-memory-recall] judge:    $JUDGE"
echo ""

# Step 1: Seed the blackboard with project facts (unless skipped).
if [[ "$SKIP_SEED" -eq 0 ]]; then
    if [[ ! -f "$DB_PATH" ]]; then
        echo "[run-memory-recall] WARNING: DB not found at $DB_PATH — skipping seed."
        echo "[run-memory-recall] Create the DB with: chump --help (first run creates it)"
    else
        echo "[run-memory-recall] Seeding blackboard_persist with EVAL-018 facts…"
        sqlite3 "$DB_PATH" < "$SEED_SQL"
        echo "[run-memory-recall] Seed complete."
    fi
    echo ""
fi

# Step 2: Run the A/B harness via the cloud driver.
python3.12 "$SCRIPT_DIR/run-cloud-v2.py" \
    --fixture "$FIXTURE" \
    --flag    CHUMP_ENTITY_PREFETCH \
    --tag     "$TAG" \
    --limit   "$LIMIT" \
    --out     "$OUT" \
    --judge   "$JUDGE" \
    --mode    ab

echo ""
echo "[run-memory-recall] done."
echo "[run-memory-recall] output:  $OUT"
echo "[run-memory-recall] summary: ${OUT%.jsonl}.summary.json"
