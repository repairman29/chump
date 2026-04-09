#!/usr/bin/env bash
# consciousness-report.sh — Generate a consciousness metrics report from the Chump DB.
#
# Reads the live DB and produces a human-readable summary to stdout and optionally
# writes JSON to logs/consciousness-report.json. Useful after battle QA runs,
# during heartbeat rounds, or as an ad-hoc diagnostic.
#
# Usage:
#   ./scripts/consciousness-report.sh                    # report to stdout
#   ./scripts/consciousness-report.sh --json             # also write JSON to logs/
#   CHUMP_MEMORY_DB_PATH=/tmp/test.db ./scripts/...     # query specific DB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

DB_PATH="${CHUMP_MEMORY_DB_PATH:-$REPO_ROOT/sessions/chump_memory.db}"
WRITE_JSON=false
[ "${1:-}" = "--json" ] && WRITE_JSON=true

if [ ! -f "$DB_PATH" ]; then
    echo "No DB found at $DB_PATH. Nothing to report."
    exit 0
fi

echo "========================================"
echo "  Consciousness Framework Report"
echo "  $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "========================================"
echo ""

# --- Surprise / Prediction Error ---
PRED_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_prediction_log;" 2>/dev/null || echo "0")
if [ "$PRED_COUNT" -gt 0 ]; then
    PRED_MEAN=$(sqlite3 "$DB_PATH" "SELECT ROUND(AVG(surprisal), 4) FROM chump_prediction_log;" 2>/dev/null || echo "0")
    PRED_HIGH=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_prediction_log WHERE surprisal > 0.5;" 2>/dev/null || echo "0")
    PRED_HIGH_PCT=$(echo "scale=1; $PRED_HIGH * 100 / $PRED_COUNT" | bc 2>/dev/null || echo "0")

    echo "SURPRISE TRACKING (Phase 1)"
    echo "  Total predictions:  $PRED_COUNT"
    echo "  Mean surprisal:     $PRED_MEAN"
    echo "  High-surprise (>0.5): $PRED_HIGH ($PRED_HIGH_PCT%)"
    echo ""
    echo "  Top surprising tools:"
    sqlite3 -column -header "$DB_PATH" "
      SELECT tool, ROUND(AVG(surprisal), 3) as avg_surprisal,
             COUNT(*) as calls,
             SUM(CASE WHEN outcome != 'ok' THEN 1 ELSE 0 END) as failures
      FROM chump_prediction_log
      GROUP BY tool
      ORDER BY AVG(surprisal) DESC LIMIT 10;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""

    echo "  Outcome distribution:"
    sqlite3 -column -header "$DB_PATH" "
      SELECT outcome, COUNT(*) as cnt, ROUND(AVG(surprisal), 3) as avg_surprisal
      FROM chump_prediction_log
      GROUP BY outcome ORDER BY cnt DESC;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""
else
    echo "SURPRISE TRACKING (Phase 1): No predictions recorded yet."
    echo ""
fi

# --- Memory Graph ---
TRIPLE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_memory_graph;" 2>/dev/null || echo "0")
if [ "$TRIPLE_COUNT" -gt 0 ]; then
    UNIQUE_SUBJ=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT subject) FROM chump_memory_graph;" 2>/dev/null || echo "0")
    UNIQUE_OBJ=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT object) FROM chump_memory_graph;" 2>/dev/null || echo "0")
    AVG_WEIGHT=$(sqlite3 "$DB_PATH" "SELECT ROUND(AVG(weight), 2) FROM chump_memory_graph;" 2>/dev/null || echo "0")

    echo "ASSOCIATIVE MEMORY GRAPH (Phase 2)"
    echo "  Total triples:     $TRIPLE_COUNT"
    echo "  Unique subjects:   $UNIQUE_SUBJ"
    echo "  Unique objects:    $UNIQUE_OBJ"
    echo "  Avg edge weight:   $AVG_WEIGHT"
    echo ""
    echo "  Top relations:"
    sqlite3 -column -header "$DB_PATH" "
      SELECT relation, COUNT(*) as cnt, ROUND(AVG(weight), 2) as avg_weight
      FROM chump_memory_graph
      GROUP BY relation ORDER BY cnt DESC LIMIT 10;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""

    echo "  Most connected entities (by degree):"
    sqlite3 -column -header "$DB_PATH" "
      SELECT entity, SUM(degree) as total_degree FROM (
        SELECT subject as entity, COUNT(*) as degree FROM chump_memory_graph GROUP BY subject
        UNION ALL
        SELECT object as entity, COUNT(*) as degree FROM chump_memory_graph GROUP BY object
      ) GROUP BY entity ORDER BY total_degree DESC LIMIT 10;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""
else
    echo "ASSOCIATIVE MEMORY GRAPH (Phase 2): No triples stored yet."
    echo ""
fi

# --- Counterfactual Reasoning ---
LESSON_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_causal_lessons;" 2>/dev/null || echo "0")
if [ "$LESSON_COUNT" -gt 0 ]; then
    AVG_CONF=$(sqlite3 "$DB_PATH" "SELECT ROUND(AVG(confidence), 2) FROM chump_causal_lessons;" 2>/dev/null || echo "0")
    TOTAL_APPLIED=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(times_applied), 0) FROM chump_causal_lessons;" 2>/dev/null || echo "0")
    APPLIED_PCT=$(echo "scale=1; $TOTAL_APPLIED * 100 / $LESSON_COUNT" | bc 2>/dev/null || echo "0")

    echo "COUNTERFACTUAL REASONING (Phase 4)"
    echo "  Total lessons:      $LESSON_COUNT"
    echo "  Avg confidence:     $AVG_CONF"
    echo "  Times applied:      $TOTAL_APPLIED (application rate: $APPLIED_PCT%)"
    echo ""
    echo "  Failure patterns (by task type):"
    sqlite3 -column -header "$DB_PATH" "
      SELECT task_type, COUNT(*) as lessons, ROUND(AVG(confidence), 2) as avg_conf,
             SUM(times_applied) as total_applied
      FROM chump_causal_lessons
      WHERE task_type != ''
      GROUP BY task_type ORDER BY COUNT(*) DESC LIMIT 10;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""

    echo "  Recent lessons:"
    sqlite3 -column "$DB_PATH" "
      SELECT id, SUBSTR(lesson, 1, 80) || '...' as lesson_preview,
             confidence, times_applied
      FROM chump_causal_lessons
      ORDER BY id DESC LIMIT 5;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""
else
    echo "COUNTERFACTUAL REASONING (Phase 4): No lessons generated yet."
    echo ""
fi

# --- Episode Sentiment ---
EPISODE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_episodes;" 2>/dev/null || echo "0")
if [ "$EPISODE_COUNT" -gt 0 ]; then
    echo "EPISODE SENTIMENT ANALYSIS"
    echo "  Total episodes: $EPISODE_COUNT"
    echo ""
    echo "  Sentiment distribution:"
    sqlite3 -column -header "$DB_PATH" "
      SELECT COALESCE(sentiment, 'unset') as sentiment, COUNT(*) as cnt,
             ROUND(COUNT(*) * 100.0 / $EPISODE_COUNT, 1) as pct
      FROM chump_episodes
      GROUP BY sentiment ORDER BY cnt DESC;
    " 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
    echo ""
fi

echo "========================================"
echo "  Framework Health Summary"
echo "========================================"
echo ""

ACTIVE_PHASES=0
[ "$PRED_COUNT" -gt 0 ] && ACTIVE_PHASES=$((ACTIVE_PHASES + 1))
[ "$TRIPLE_COUNT" -gt 0 ] && ACTIVE_PHASES=$((ACTIVE_PHASES + 1))
[ "$LESSON_COUNT" -gt 0 ] && ACTIVE_PHASES=$((ACTIVE_PHASES + 1))

echo "  Active phases:     $ACTIVE_PHASES / 6 (Phases 3, 5, 6 are in-memory only)"
echo "  Prediction volume: $PRED_COUNT"
echo "  Graph density:     $TRIPLE_COUNT triples"
echo "  Learning depth:    $LESSON_COUNT causal lessons"
echo ""

if [ "$ACTIVE_PHASES" -eq 0 ]; then
    echo "  STATUS: Framework installed but not yet exercised."
    echo "  NEXT:   Run the bot in Discord or CLI to generate prediction data."
elif [ "$ACTIVE_PHASES" -lt 3 ]; then
    echo "  STATUS: Partially active. Some subsystems generating data."
    echo "  NEXT:   Use memory store + episode log to populate graph and lessons."
else
    echo "  STATUS: All persistent phases active. Generating data."
    echo "  NEXT:   Run consciousness-baseline.sh to snapshot, then compare after tuning."
fi
echo ""

# --- Optional JSON output ---
if $WRITE_JSON; then
    "$SCRIPT_DIR/consciousness-baseline.sh" > /dev/null 2>&1
    echo "JSON baseline also written to: $LOG_DIR/consciousness-baseline.json"
fi
