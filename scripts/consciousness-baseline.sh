#!/usr/bin/env bash
# consciousness-baseline.sh — Capture baseline metrics for all 6 Synthetic Consciousness modules.
#
# Runs against the live DB (or a temp DB if CHUMP_MEMORY_DB_PATH is set to a temp location)
# and produces a structured JSON baseline to logs/consciousness-baseline.json.
#
# Usage:
#   ./scripts/consciousness-baseline.sh                    # query live DB
#   CHUMP_MEMORY_DB_PATH=/tmp/test.db ./scripts/...       # query specific DB
#
# If CHUMP_HEALTH_PORT is set and the health server is reachable, also captures
# the /health consciousness_dashboard as the authoritative runtime snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

OUTPUT="$LOG_DIR/consciousness-baseline.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

DB_PATH="${CHUMP_MEMORY_DB_PATH:-$REPO_ROOT/sessions/chump_memory.db}"

echo "=== Consciousness Baseline Capture ==="
echo "Timestamp: $TIMESTAMP"
echo "DB path:   $DB_PATH"

# --- SQL-based metrics (always available if DB exists) ---

if [ ! -f "$DB_PATH" ]; then
    echo "WARNING: DB not found at $DB_PATH. Creating baseline with zeros."
    cat > "$OUTPUT" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "db_path": "$DB_PATH",
  "db_exists": false,
  "surprise": { "total_predictions": 0, "mean_surprisal": 0, "high_surprise_tools": [] },
  "memory_graph": { "triple_count": 0, "unique_entities": 0 },
  "counterfactual": { "lesson_count": 0, "failure_patterns": [] },
  "health_snapshot": null
}
EOF
    echo "Baseline written to $OUTPUT"
    exit 0
fi

echo "Querying DB..."

# Prediction log stats
PRED_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_prediction_log;" 2>/dev/null || echo "0")
PRED_MEAN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(AVG(surprisal), 0) FROM chump_prediction_log;" 2>/dev/null || echo "0")
PRED_HIGH_PCT=$(sqlite3 "$DB_PATH" "SELECT COALESCE(
  CAST(SUM(CASE WHEN surprisal > 0.5 THEN 1 ELSE 0 END) AS REAL) / NULLIF(COUNT(*), 0) * 100,
  0) FROM chump_prediction_log;" 2>/dev/null || echo "0")

# Top surprising tools (by avg surprisal, min 2 calls)
TOP_SURPRISE=$(sqlite3 -json "$DB_PATH" "
  SELECT tool, ROUND(AVG(surprisal), 3) as avg_surprisal, COUNT(*) as calls
  FROM chump_prediction_log
  GROUP BY tool HAVING COUNT(*) >= 2
  ORDER BY AVG(surprisal) DESC LIMIT 10;
" 2>/dev/null)
[ -z "$TOP_SURPRISE" ] && TOP_SURPRISE="[]"

# Memory graph stats
TRIPLE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_memory_graph;" 2>/dev/null || echo "0")
UNIQUE_SUBJECTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT subject) FROM chump_memory_graph;" 2>/dev/null || echo "0")
UNIQUE_OBJECTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT object) FROM chump_memory_graph;" 2>/dev/null || echo "0")
UNIQUE_ENTITIES=$((UNIQUE_SUBJECTS + UNIQUE_OBJECTS))
TOP_RELATIONS=$(sqlite3 -json "$DB_PATH" "
  SELECT relation, COUNT(*) as cnt
  FROM chump_memory_graph
  GROUP BY relation ORDER BY cnt DESC LIMIT 10;
" 2>/dev/null)
[ -z "$TOP_RELATIONS" ] && TOP_RELATIONS="[]"

# Counterfactual stats
LESSON_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_causal_lessons;" 2>/dev/null || echo "0")
AVG_CONFIDENCE=$(sqlite3 "$DB_PATH" "SELECT COALESCE(AVG(confidence), 0) FROM chump_causal_lessons;" 2>/dev/null || echo "0")
TOTAL_APPLIED=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(times_applied), 0) FROM chump_causal_lessons;" 2>/dev/null || echo "0")
FAILURE_PATTERNS=$(sqlite3 -json "$DB_PATH" "
  SELECT task_type, COUNT(*) as cnt
  FROM chump_causal_lessons
  WHERE task_type != ''
  GROUP BY task_type ORDER BY cnt DESC LIMIT 10;
" 2>/dev/null)
[ -z "$FAILURE_PATTERNS" ] && FAILURE_PATTERNS="[]"

# Episode sentiment distribution
EPISODE_SENTIMENTS=$(sqlite3 -json "$DB_PATH" "
  SELECT COALESCE(sentiment, 'null') as sentiment, COUNT(*) as cnt
  FROM chump_episodes
  GROUP BY sentiment ORDER BY cnt DESC;
" 2>/dev/null)
[ -z "$EPISODE_SENTIMENTS" ] && EPISODE_SENTIMENTS="[]"
EPISODE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chump_episodes;" 2>/dev/null || echo "0")

# --- Health endpoint snapshot (if reachable) ---

HEALTH_SNAPSHOT="null"
HEALTH_PORT="${CHUMP_HEALTH_PORT:-}"
if [ -n "$HEALTH_PORT" ]; then
    echo "Probing health endpoint on port $HEALTH_PORT..."
    HEALTH_SNAPSHOT=$(curl -s --connect-timeout 2 "http://127.0.0.1:${HEALTH_PORT}/health" 2>/dev/null || echo "null")
    if [ "$HEALTH_SNAPSHOT" = "null" ] || [ -z "$HEALTH_SNAPSHOT" ]; then
        echo "  Health endpoint not reachable."
        HEALTH_SNAPSHOT="null"
    else
        echo "  Health snapshot captured."
    fi
fi

# --- Assemble baseline JSON ---

cat > "$OUTPUT" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "db_path": "$DB_PATH",
  "db_exists": true,
  "surprise": {
    "total_predictions": $PRED_COUNT,
    "mean_surprisal": $PRED_MEAN,
    "high_surprise_pct": $PRED_HIGH_PCT,
    "top_surprising_tools": $TOP_SURPRISE
  },
  "memory_graph": {
    "triple_count": $TRIPLE_COUNT,
    "unique_entities": $UNIQUE_ENTITIES,
    "top_relations": $TOP_RELATIONS
  },
  "counterfactual": {
    "lesson_count": $LESSON_COUNT,
    "avg_confidence": $AVG_CONFIDENCE,
    "total_times_applied": $TOTAL_APPLIED,
    "failure_patterns": $FAILURE_PATTERNS
  },
  "episodes": {
    "total": $EPISODE_COUNT,
    "sentiment_distribution": $EPISODE_SENTIMENTS
  },
  "health_snapshot": $HEALTH_SNAPSHOT
}
EOF

echo ""
echo "=== Baseline Summary ==="
echo "  Predictions:     $PRED_COUNT (mean surprisal: $PRED_MEAN, high%: $PRED_HIGH_PCT)"
echo "  Graph triples:   $TRIPLE_COUNT ($UNIQUE_ENTITIES unique entities)"
echo "  Causal lessons:  $LESSON_COUNT (avg confidence: $AVG_CONFIDENCE, applied: $TOTAL_APPLIED)"
echo "  Episodes:        $EPISODE_COUNT"
echo ""
echo "Full baseline written to: $OUTPUT"
