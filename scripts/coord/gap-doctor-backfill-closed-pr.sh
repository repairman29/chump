#!/usr/bin/env bash
# scripts/coord/gap-doctor-backfill-closed-pr.sh — INFRA-319
#
# Backfill `gaps.closed_pr` in state.db for done-but-no-PR gaps.
# Caught 2026-05-02: state.db had 300 gaps with status=done AND
# closed_pr IS NULL. Most (290) were 2026-04 historical, before strict
# PR-tracking landed. Recoverable: gh has the merged PR for each (titles
# follow the canonical "<GAP-ID>: ..." format).
#
# Strategy: for each done-no-PR gap, ask `gh pr list --state merged
# --search "<GAP-ID> in:title"` for the closing PR and set closed_pr in
# state.db. Skip gaps where no PR is found (true historical orphans —
# the gap closed via direct main push or before tracking).
#
# State.db is gitignored so this MUST run locally on each operator's
# machine. Idempotent — gaps that already have closed_pr are skipped.
#
# Usage:
#   bash scripts/coord/gap-doctor-backfill-closed-pr.sh             # apply
#   bash scripts/coord/gap-doctor-backfill-closed-pr.sh --dry-run   # report only
#   bash scripts/coord/gap-doctor-backfill-closed-pr.sh --limit 20  # cap (debug)
#
# Pairs with: gap-doctor.py (drift detector, INFRA-245),
# gap-doctor-reconcile.py (YAML→DB field reconciler, INFRA-303 + 316),
# gap-normalize-domains.sh (domain-field hygiene, INFRA-318).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

DRY=0
LIMIT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --limit)   LIMIT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$DB" ]]; then
    echo "ERROR: state.db missing at $DB" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI required" >&2
    exit 2
fi
if ! command -v chump >/dev/null 2>&1; then
    echo "ERROR: chump binary required (cargo install --path . --bin chump)" >&2
    exit 2
fi

# Find done-no-PR gaps.
QUERY="SELECT id FROM gaps WHERE status='done' AND closed_pr IS NULL ORDER BY closed_date DESC, id"
[[ "$LIMIT" -gt 0 ]] && QUERY="$QUERY LIMIT $LIMIT"

GAPS="$(sqlite3 "$DB" "$QUERY;")"
TOTAL="$(printf '%s\n' "$GAPS" | grep -c .)"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "[backfill] no done-no-PR gaps — nothing to do"
    exit 0
fi

echo "[backfill] $TOTAL done-no-PR gaps to scan"
[[ "$DRY" -eq 1 ]] && echo "[backfill] DRY-RUN — no writes"

filled=0
not_found=0
errors=0

while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue
    # gh pr list with title-anchored search; take first MERGED match.
    pr="$(gh pr list --state merged --search "$gap in:title" --json number,title \
            -q ".[] | select(.title | startswith(\"$gap\")) | .number" 2>/dev/null \
            | head -1 || true)"
    if [[ -z "$pr" ]]; then
        not_found=$((not_found + 1))
        continue
    fi
    if [[ "$DRY" -eq 1 ]]; then
        echo "  $gap  → would set closed_pr=#$pr"
        filled=$((filled + 1))
        continue
    fi
    if chump gap set "$gap" --closed-pr "$pr" >/dev/null 2>&1; then
        filled=$((filled + 1))
        # Light progress every 10
        [[ $((filled % 10)) -eq 0 ]] && echo "  ...filled $filled so far"
    else
        errors=$((errors + 1))
        echo "  WARN $gap: chump gap set --closed-pr $pr failed" >&2
    fi
done <<< "$GAPS"

echo
echo "[backfill] summary:"
echo "  scanned     : $TOTAL"
echo "  filled      : $filled"
echo "  not-found   : $not_found  (no merged PR with this gap-ID in title — true historical orphans)"
echo "  errors      : $errors"
[[ "$DRY" -eq 1 ]] && echo "  (dry-run — no writes applied)"
