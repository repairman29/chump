#!/usr/bin/env bash
# backfill-yaml-opened-dates.sh — INFRA-1611
#
# Companion to scripts/dev/backfill-opened-dates.sh (EVAL-086), which stamps
# `opened_date` into state.db (local, gitignored). This script stamps the
# same field directly into the committed per-file docs/gaps/*.yaml dumps so
# scripts/ci/test-gap-opened-date-coverage.sh has real, git-tracked evidence
# to check on a fresh CI checkout (which never has state.db).
#
# Strategy per open P0/P1 gap file missing opened_date:
#   1. git log --diff-filter=A on docs/gaps/<ID>.yaml -> date file first appeared
#   2. Fall back to the earliest commit that touches the file at all
#
# Usage:
#   scripts/dev/backfill-yaml-opened-dates.sh [--dry-run] [--all]
#     --all: backfill every open gap, not just P0/P1

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
ALL=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --all) ALL=1 ;;
    esac
done

updated=0
skipped=0

for f in docs/gaps/*.yaml; do
    status="$(grep -m1 '^  status:' "$f" | awk '{print $2}' || true)"
    [[ "$status" != "open" ]] && continue

    if grep -q '^  opened_date:' "$f"; then
        continue
    fi

    if [[ "$ALL" -ne 1 ]]; then
        priority="$(grep -m1 '^  priority:' "$f" | awk '{print $2}' || true)"
        [[ "$priority" != "P0" && "$priority" != "P1" ]] && continue
    fi

    gap_id="$(grep -m1 '^- id:' "$f" | sed 's/^- id: *//')"
    [[ -z "$gap_id" ]] && continue

    date_to_use="$(git log --diff-filter=A --pretty=format:"%ad" --date=short -- "$f" 2>/dev/null | tail -1 || true)"
    if [[ -z "$date_to_use" ]]; then
        date_to_use="$(git log --pretty=format:"%ad" --date=short -- "$f" 2>/dev/null | tail -1 || true)"
    fi
    if [[ -z "$date_to_use" ]]; then
        echo "  SKIP $gap_id -- no git history for $f" >&2
        skipped=$((skipped + 1))
        continue
    fi

    prefix=""; [[ "$DRY_RUN" -eq 1 ]] && prefix="[DRY-RUN] "
    echo "  ${prefix}UPDATE $gap_id opened_date=$date_to_use"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        # Insert right after the `effort:` line to match the field order
        # write_yaml_op uses in crates/chump-gap-store (id, domain, title,
        # status, priority, effort, opened_date, ...).
        awk -v date="$date_to_use" '
            { print }
            /^  effort:/ && !done { print "  opened_date: " date; done=1 }
        ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    updated=$((updated + 1))
done

echo ""
echo "Backfill complete: updated=$updated skipped=$skipped dry_run=$DRY_RUN"
