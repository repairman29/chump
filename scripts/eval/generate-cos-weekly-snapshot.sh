#!/usr/bin/env bash
# Chief-of-staff weekly snapshot: tasks + episodes from chump_memory.db → logs/cos-weekly-YYYY-MM-DD.md
# Usage: ./scripts/eval/generate-cos-weekly-snapshot.sh [CHUMP_HOME]
# Requires: sqlite3 on PATH. Safe read-only on the DB.
set -euo pipefail
ROOT="${1:-${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}}"
DB="$ROOT/sessions/chump_memory.db"
OUT_DIR="$ROOT/logs"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y-%m-%d)"
OUT="$OUT_DIR/cos-weekly-${STAMP}.md"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 not found; install SQLite CLI." >&2
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "No DB at $DB — run Chump once or set CHUMP_HOME." >&2
  exit 1
fi

{
  echo "# COS weekly snapshot"
  echo ""
  echo "**Generated (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**DB:** \`$DB\`"
  echo ""
  echo "## Tasks by status"
  echo ""
  sqlite3 -header -column "$DB" "SELECT status, COUNT(*) AS n FROM chump_tasks GROUP BY status ORDER BY n DESC;" || echo "(no chump_tasks table or empty)"
  echo ""
  echo "## Open / in-progress tasks (top 20 by priority, then id)"
  echo ""
  sqlite3 -header -column "$DB" "SELECT id, priority, status, substr(title,1,80) AS title, assignee FROM chump_tasks WHERE status IN ('open','in_progress','blocked') ORDER BY priority DESC, id DESC LIMIT 20;" || true
  echo ""
  echo "## Recent episodes (15)"
  echo ""
  sqlite3 -header -column "$DB" "SELECT id, happened_at, sentiment, substr(summary,1,100) AS summary FROM chump_episodes ORDER BY id DESC LIMIT 15;" || true
  echo ""
  echo "---"
  echo "Roadmap: [docs/strategy/PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](../docs/strategy/PRODUCT_ROADMAP_CHIEF_OF_STAFF.md)"
} >"$OUT"

echo "Wrote $OUT"
