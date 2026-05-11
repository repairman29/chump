#!/usr/bin/env bash
# backfill-opened-dates.sh — EVAL-086: stamp opened_date for open gaps missing it.
#
# Strategy (per gap with empty opened_date):
#   1. git log --diff-filter=A on docs/gaps/<ID>.yaml → date file first appeared
#   2. Fall back to created_at (Unix timestamp) if no YAML commit found
#
# Usage:
#   scripts/dev/backfill-opened-dates.sh [--dry-run]

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve main repo (works from linked worktrees) — same pattern as repo-paths.sh.
_GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_DIR" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON_DIR/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
fi
unset _GIT_COMMON_DIR

DB="$MAIN_REPO/.chump/state.db"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -f "$DB" ]]; then
    echo "ERROR: state.db not found at $DB" >&2
    exit 1
fi

updated=0
skipped=0

# Read all open gaps with empty opened_date into a temp file to avoid
# holding a read cursor while we do git operations.
TMP_IDS="$(mktemp)"
sqlite3 "$DB" "SELECT id, created_at FROM gaps WHERE status='open' AND (opened_date IS NULL OR opened_date='') ORDER BY id" \
    > "$TMP_IDS"

while IFS='|' read -r gap_id created_at_ts; do
    [[ -z "$gap_id" ]] && continue

    # Strategy 1: git log for YAML file
    yaml_date=""
    yaml_path="docs/gaps/${gap_id}.yaml"
    yaml_date="$(git -C "$REPO_ROOT" log --diff-filter=A --pretty=format:"%ad" \
        --date=short -- "$yaml_path" 2>/dev/null | head -1 || true)"

    if [[ -n "$yaml_date" ]]; then
        date_to_use="$yaml_date"
        source="yaml_commit"
    elif [[ -n "$created_at_ts" && "$created_at_ts" -gt 0 ]]; then
        # Strategy 2: derive from created_at Unix timestamp
        date_to_use="$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp(int('$created_at_ts'), tz=timezone.utc).strftime('%Y-%m-%d'))
" 2>/dev/null || true)"
        source="created_at"
    else
        echo "  SKIP $gap_id — no yaml, no created_at" >&2
        ((skipped++)) || true
        continue
    fi

    if [[ -z "$date_to_use" ]]; then
        echo "  SKIP $gap_id — could not derive date" >&2
        ((skipped++)) || true
        continue
    fi

    local_prefix=""; [[ "$DRY_RUN" -eq 1 ]] && local_prefix="[DRY-RUN] "
    echo "  ${local_prefix}UPDATE $gap_id opened_date=$date_to_use (source=$source)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        sqlite3 "$DB" "UPDATE gaps SET opened_date='$date_to_use' WHERE id='$gap_id'"
    fi
    ((updated++)) || true
done < "$TMP_IDS"

rm -f "$TMP_IDS"

echo ""
echo "Backfill complete: updated=$updated skipped=$skipped dry_run=$DRY_RUN"
