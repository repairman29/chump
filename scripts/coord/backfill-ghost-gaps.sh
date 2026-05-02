#!/usr/bin/env bash
# backfill-ghost-gaps.sh — INFRA-241 one-shot historical ghost sweep.
#
# Walks every status:open per-file YAML in docs/gaps/, queries `gh pr list`
# for the closing PR (most recent merged PR whose title contains the gap-ID
# and is NOT a filing/closure-only PR), and surgically writes status:done +
# closed_pr + closed_date.
#
# Safety:
#   - Skips filing PRs (title prefix `chore(gaps): file`)
#   - Skips closure-only ledger PRs (title prefix `chore(gaps): close`)
#   - Skips backfill PRs (title prefix `chore(gaps): backfill`)
#   - Idempotent: re-running on already-done gaps is no-op (we never enter
#     the modify branch unless current status is `open`)
#   - Single-author closure: prefers the most recent matching PR over older
#     ones, since that's typically the implementation rather than a side
#     mention
#
# Usage: ./scripts/coord/backfill-ghost-gaps.sh [--dry-run]

set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GAPS_DIR="$REPO_ROOT/docs/gaps"
TODAY="$(date -u +%Y-%m-%d)"

if [ ! -d "$GAPS_DIR" ]; then
    echo "[backfill] ERROR: $GAPS_DIR not found" >&2
    exit 1
fi

closed=0
skipped_no_pr=0
skipped_filing_only=0
skipped_already_done=0

for yaml_path in "$GAPS_DIR"/*.yaml; do
    gap_id="$(basename "$yaml_path" .yaml)"
    current_status="$(awk '/^[[:space:]]*status:/ {print $2; exit}' "$yaml_path" 2>/dev/null || true)"

    if [ "$current_status" != "open" ]; then
        skipped_already_done=$((skipped_already_done + 1))
        continue
    fi

    # Find the most recent merged PR with the gap-ID in the title that is
    # NOT a filing/closure-only ledger PR. Pull a few in case the most
    # recent IS a ledger PR (e.g. a chore(gaps): close that referenced this
    # gap as part of a multi-close commit).
    candidates="$(gh pr list \
        --state merged \
        --search "in:title $gap_id" \
        --json number,title,mergedAt \
        --limit 10 \
        --jq '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)"

    if [ -z "$candidates" ]; then
        skipped_no_pr=$((skipped_no_pr + 1))
        continue
    fi

    chosen_pr=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pr_num="${line%%|*}"
        pr_title="${line#*|}"
        # Skip filing / closure / backfill PRs.
        case "$pr_title" in
            "chore(gaps): file"*|"chore(gaps): close"*|"chore(gaps): backfill"*)
                continue
                ;;
        esac
        chosen_pr="$pr_num"
        break
    done <<< "$candidates"

    if [ -z "$chosen_pr" ]; then
        skipped_filing_only=$((skipped_filing_only + 1))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[backfill] DRY: would close $gap_id (PR #$chosen_pr)"
        closed=$((closed + 1))
        continue
    fi

    # Surgical edit: flip status:open → status:done, insert closed_pr +
    # closed_date right after status. Mirrors close-gaps-from-commit-
    # subjects.sh logic so future audits are byte-stable across both
    # closure paths.
    tmp="$yaml_path.tmp.$$"
    awk -v pr="$chosen_pr" -v today="$TODAY" '
        BEGIN { inserted=0 }
        /^[[:space:]]*status:[[:space:]]*open[[:space:]]*$/ && !inserted {
            match($0, /^[[:space:]]*/)
            indent = substr($0, RSTART, RLENGTH)
            print indent "status: done"
            print indent "closed_pr: " pr
            print indent "closed_date: " "'\''" today "'\''"
            inserted = 1
            next
        }
        { print }
    ' "$yaml_path" > "$tmp"

    old_lines="$(wc -l < "$yaml_path")"
    new_lines="$(wc -l < "$tmp")"
    if [ "$((new_lines - old_lines))" -ne 2 ]; then
        echo "[backfill] WARN: line-count check failed for $gap_id (old=$old_lines new=$new_lines), skipping" >&2
        rm -f "$tmp"
        continue
    fi

    mv "$tmp" "$yaml_path"
    echo "[backfill] closed $gap_id (PR #$chosen_pr)"
    closed=$((closed + 1))
done

echo ""
echo "[backfill] summary: closed=$closed skipped_no_pr=$skipped_no_pr skipped_filing_only=$skipped_filing_only skipped_already_done=$skipped_already_done"
exit 0
