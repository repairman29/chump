#!/usr/bin/env bash
# scripts/coord/ghost-pr-closer.sh — META-225
#
# Ghost-PR closer: scans open PRs, finds those whose gap is already
# status=done AND PR is DIRTY/CONFLICTING, and closes them automatically.
#
# A "ghost PR" is a PR where the underlying work has already shipped (gap is
# done) but the PR branch was left open, often in a conflicting state. These
# clutter the queue and cause noise in DIRTY-count monitors.
#
# Emission kinds:
# scanner-anchor: "kind":"ghost_pr_closed"
#
# Self-throttle: max 5 closes per run. Overflowed findings go to
# .chump/ghost-pr-deferred.jsonl for next run.
#
# Usage:
#   bash scripts/coord/ghost-pr-closer.sh [--dry-run]
#
# Env knobs:
#   CHUMP_GHOST_CLOSER_AMBIENT_FILE     — override ambient.jsonl path (tests)
#   CHUMP_GHOST_CLOSER_DEFERRED_FILE    — override deferred.jsonl path (tests)
#   CHUMP_GHOST_CLOSER_GH_FIXTURE       — path to fixture JSON (tests only)
#   CHUMP_GHOST_CLOSER_CHUMP_CMD        — override chump binary (tests only)
#   CHUMP_GHOST_CLOSER_GH_CMD           — override gh binary (tests only)
#   CHUMP_GHOST_CLOSER_MAX_CLOSES       — max closes per run (default 5)
#   CHUMP_GHOST_CLOSER_DRY_RUN          — set to 1 to skip gh pr close (tests)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$(dirname "$_GIT_COMMON")" && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="$MAIN_REPO/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"

# ── Configuration ─────────────────────────────────────────────────────────────
AMBIENT="${CHUMP_GHOST_CLOSER_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
DEFERRED="${CHUMP_GHOST_CLOSER_DEFERRED_FILE:-$CHUMP_DIR/ghost-pr-deferred.jsonl}"
GH="${CHUMP_GHOST_CLOSER_GH_CMD:-gh}"
CHUMP="${CHUMP_GHOST_CLOSER_CHUMP_CMD:-chump}"
MAX_CLOSES="${CHUMP_GHOST_CLOSER_MAX_CLOSES:-5}"
DRY_RUN="${CHUMP_GHOST_CLOSER_DRY_RUN:-0}"

for _a in "$@"; do
    case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[ghost-pr-closer] %s\n' "$*"; }

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# extract_gap_id TITLE — extract gap ID from PR title.
# Matches: INFRA-NNN META-NNN CREDIBLE-NNN RESILIENT-NNN EFFECTIVE-NNN
#          FLEET-NNN DOC-NNN MEM-NNN VOA-NNN SCALE-NNN
extract_gap_id() {
    printf '%s' "$1" | grep -oE '(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-[0-9]+' | head -1
}

# gap_status GAP_ID — get status from chump gap show.
gap_status() {
    local gap_id="$1"
    "$CHUMP" gap show "$gap_id" 2>/dev/null | grep -E '^  status:' | awk '{print $2}' | tr -d '"'
}

# gap_closed_pr GAP_ID — get closed_pr from chump gap show (may be empty).
gap_closed_pr() {
    local gap_id="$1"
    "$CHUMP" gap show "$gap_id" 2>/dev/null | grep -E '^  closed_pr:' | awk '{print $2}' | tr -d '"'
}

# ── Step 1: Get open PRs ──────────────────────────────────────────────────────
if [[ -n "${CHUMP_GHOST_CLOSER_GH_FIXTURE:-}" ]]; then
    PRS_JSON="$(cat "$CHUMP_GHOST_CLOSER_GH_FIXTURE")"
else
    PRS_JSON="$(CHUMP_GH_CALL_CRITICALITY=background "$GH" pr list \
        --state open \
        --limit 100 \
        --json number,title,mergeStateStatus \
        2>/dev/null || echo '[]')"
fi

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    log "No open PRs found (or gh unavailable)."
    exit 0
fi

# Parse into TSV: number<tab>title<tab>mergeStateStatus
PRS_TSV="$(printf '%s' "$PRS_JSON" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    print('\t'.join([
        str(r.get('number','')),
        (r.get('title') or '').replace('\t',' '),
        r.get('mergeStateStatus','') or '',
    ]))
" 2>/dev/null || true)"

if [[ -z "$PRS_TSV" ]]; then
    log "No PRs to process."
    exit 0
fi

# ── Step 2: Process each PR ───────────────────────────────────────────────────
CLOSES=0
DEFERRED_COUNT_NEW=0
SKIP_OPEN=0
SKIP_NO_ID=0

# Process deferred items from last run first (DEFERRED is the file path)
if [[ -f "$DEFERRED" ]]; then
    PREV_DEFERRED_COUNT="$(wc -l < "$DEFERRED" | tr -d ' ')"
    log "Found $PREV_DEFERRED_COUNT deferred findings from previous run"
    # Re-queue them at the front by prepending to current batch
    DEFERRED_TSV="$(python3 -c "
import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        print('\t'.join([str(d['number']), d['title'], d['mergeStateStatus']]))
    except Exception:
        pass
" < "$DEFERRED" 2>/dev/null || true)"
    # Clear deferred file (will re-write any new overflow)
    : > "$DEFERRED"
    PRS_TSV="$(printf '%s\n%s' "$DEFERRED_TSV" "$PRS_TSV" | grep -v '^$')"
fi

while IFS=$'\t' read -r PR_NUM TITLE MSS; do
    [[ -z "$PR_NUM" ]] && continue

    # Only act on DIRTY or CONFLICTING merge state
    if [[ "$MSS" != "DIRTY" && "$MSS" != "CONFLICTING" ]]; then
        SKIP_OPEN=$((SKIP_OPEN + 1))
        continue
    fi

    # Extract gap ID from title
    gap_id="$(extract_gap_id "$TITLE")"
    if [[ -z "$gap_id" ]]; then
        log "  SKIP #$PR_NUM — no gap ID found in title: '$TITLE'"
        SKIP_NO_ID=$((SKIP_NO_ID + 1))
        continue
    fi

    # Check gap status
    status="$(gap_status "$gap_id")"
    if [[ "$status" != "done" ]]; then
        SKIP_OPEN=$((SKIP_OPEN + 1))
        continue
    fi

    # This is a ghost PR — gap is done but PR is DIRTY/CONFLICTING
    log "Found ghost PR #$PR_NUM (gap=$gap_id status=done mergeStateStatus=$MSS)"

    # Throttle check
    if (( CLOSES >= MAX_CLOSES )); then
        log "  DEFER #$PR_NUM — reached max $MAX_CLOSES closes for this run"
        printf '{"number":%s,"title":"%s","mergeStateStatus":"%s"}\n' \
            "$PR_NUM" "$(printf '%s' "$TITLE" | sed 's/"/\\"/g')" "$MSS" \
            >> "$DEFERRED"
        DEFERRED_COUNT_NEW=$((DEFERRED_COUNT_NEW + 1))
        continue
    fi

    # Get closed_pr for context in comment
    closed_pr="$(gap_closed_pr "$gap_id")"
    closed_pr_msg=""
    [[ -n "$closed_pr" ]] && closed_pr_msg=" (already merged as PR #${closed_pr})"

    if (( DRY_RUN )); then
        log "  DRY-RUN: would close #$PR_NUM"
        continue
    fi

    # Close the ghost PR
    ts="$(_ts)"
    comment="Ghost — gap ${gap_id} already status=done${closed_pr_msg}; closing per META-225 auto-fixer at ${ts}"
    if "$GH" pr close "$PR_NUM" --comment "$comment" 2>/dev/null; then
        log "  CLOSED #$PR_NUM"
        emit "ghost_pr_closed" "\"pr\":$PR_NUM,\"gap_id\":\"$gap_id\",\"gap_closed_pr\":\"$closed_pr\",\"ts\":\"$ts\""
        CLOSES=$((CLOSES + 1))
    else
        log "  FAIL: could not close #$PR_NUM"
    fi

done <<< "$PRS_TSV"

log "done — closed=${CLOSES} deferred=${DEFERRED_COUNT_NEW} skipped_open=${SKIP_OPEN} skipped_no_id=${SKIP_NO_ID}"
exit 0
