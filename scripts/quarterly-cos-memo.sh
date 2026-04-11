#!/usr/bin/env bash
# W4.4 — Quarterly COS memo: tasks + episodes (SQLite) + recent git commits → Markdown in logs/.
# Usage: ./scripts/quarterly-cos-memo.sh [CHUMP_HOME]
# Requires: sqlite3, git. Read-only on DB.

set -euo pipefail
ROOT="${1:-${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}}"
DB="$ROOT/sessions/chump_memory.db"
OUT_DIR="$ROOT/logs"
mkdir -p "$OUT_DIR"

y=$(date +%Y)
m=$((10#$(date +%m)))
q=4
case $m in 1|2|3) q=1;; 4|5|6) q=2;; 7|8|9) q=3;; *) q=4;; esac
STAMP="${y}-Q${q}"
OUT="$OUT_DIR/cos-quarterly-${STAMP}.md"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 not found" >&2
  exit 1
fi

{
  echo "# COS quarterly memo — ${STAMP}"
  echo ""
  echo "**Generated (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**Repo:** \`$ROOT\` **DB:** \`$DB\`"
  echo ""
  echo "## Task counts by status"
  echo ""
  if [[ -f "$DB" ]]; then
    sqlite3 -header -column "$DB" "SELECT status, COUNT(*) AS n FROM chump_tasks GROUP BY status ORDER BY n DESC;" || echo "(no tasks)"
    echo ""
    echo "## Open / in-progress / blocked (top 30)"
    echo ""
    sqlite3 -header -column "$DB" "SELECT id, priority, status, substr(title,1,90) AS title, assignee FROM chump_tasks WHERE status IN ('open','in_progress','blocked') ORDER BY priority DESC, id DESC LIMIT 30;" || true
    echo ""
    echo "## Recent episodes (40)"
    echo ""
    sqlite3 -header -column "$DB" "SELECT id, happened_at, sentiment, substr(summary,1,120) AS summary FROM chump_episodes ORDER BY id DESC LIMIT 40;" || true
  else
    echo "(no DB at $DB)"
  fi
  echo ""
  echo "## Recent git commits (repo root, last 40)"
  echo ""
  if [[ -d "$ROOT/.git" ]]; then
    git -C "$ROOT" log -40 --oneline --no-decorate 2>/dev/null || echo "(git log failed)"
  else
    echo "(not a git checkout)"
  fi
  echo ""
  echo "---"
  echo "- [Product roadmap](../docs/PRODUCT_ROADMAP_CHIEF_OF_STAFF.md)"
  echo "- [Problem validation](../docs/PROBLEM_VALIDATION_CHECKLIST.md)"
  echo "- Weekly snapshot: \`./scripts/generate-cos-weekly-snapshot.sh\`"
} >"$OUT"

echo "Wrote $OUT"
