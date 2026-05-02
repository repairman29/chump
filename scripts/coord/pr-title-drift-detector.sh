#!/usr/bin/env bash
# pr-title-drift-detector.sh — INFRA-104
#
# Detects PRs whose title claims gap-ID work but the diff has no signature of
# that gap actually being addressed. Catches the "INFRA-XXX: rename file Y"
# titled PR whose actual diff only edits an unrelated docs/Z.md.
#
# Why: complementary to INFRA-236 (commit-subject closer). #236 closes
# correctly-titled PRs; this catches incorrectly-titled ones BEFORE they
# auto-close a gap that didn't actually get done.
#
# Heuristic — alert on a PR if ALL true:
#   1. Title contains a gap-ID matching ^[A-Z]+-[0-9]+
#   2. The gap-ID does NOT appear anywhere in:
#        - the diff content (any file's added/removed lines)
#        - any modified file path (e.g. docs/gaps/<ID>.yaml)
#        - the PR body
#
# Skips:
#   - Filing PRs (title prefix "chore(gaps): file") — these legitimately
#     just file the gap; their diff IS docs/gaps/<ID>.yaml which contains
#     the ID anyway, so they typically won't trip
#   - Multi-gap closure PRs (title prefix "chore(gaps): close" /
#     "chore(gaps): backfill") — same logic
#
# Usage:
#   pr-title-drift-detector.sh <PR-NUMBER>     # check one PR
#   pr-title-drift-detector.sh --recent N       # check last N merged PRs
#   pr-title-drift-detector.sh --quiet          # ALERT only, no progress stdout
#
# Env:
#   CHUMP_AMBIENT_LOG=<path>   # override ambient.jsonl path (test fixture)

set -euo pipefail

QUIET=0
PR_NUMBER=""
RECENT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --recent)  RECENT="$2"; shift 2 ;;
        --quiet)   QUIET=1; shift ;;
        --help|-h) sed -n '2,28p' "$0"; exit 0 ;;
        --*)       echo "unknown flag: $1" >&2; exit 2 ;;
        *)         PR_NUMBER="$1"; shift ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

emit_alert() {
    local pr="$1" title="$2" gap_id="$3"
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    local ts session worktree title_escaped
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    session=${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-pr-title-drift-detector}}
    worktree=$(basename "$REPO_ROOT")
    title_escaped=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"ts":"%s","session":"%s","worktree":"%s","event":"ALERT","kind":"pr_title_drift","pr":%d,"gap_id":"%s","title":"%s","note":"PR title claims %s but diff/body have no signature of that gap"}\n' \
        "$ts" "$session" "$worktree" "$pr" "$gap_id" "$title_escaped" "$gap_id" >> "$AMBIENT_LOG" 2>/dev/null || true
}

check_one_pr() {
    local pr="$1"

    # Pull title + body in one shot.
    local title body
    title=$(gh pr view "$pr" --json title -q .title 2>/dev/null || true)
    if [ -z "$title" ]; then
        [ "$QUIET" -eq 0 ] && echo "[drift] PR #$pr — could not fetch title (skipping)"
        return 0
    fi

    # Skip ledger-only PRs by title prefix.
    case "$title" in
        "chore(gaps): file"*|"chore(gaps): close"*|"chore(gaps): backfill"*)
            [ "$QUIET" -eq 0 ] && echo "[drift] PR #$pr [SKIP: ledger PR] — $title"
            return 0
            ;;
    esac

    # Extract gap-IDs from title. grep returns 1 when no match; under
    # `set -e + pipefail` that aborts the script. `|| true` keeps the
    # no-match case as the silent skip-no-id branch below.
    local gap_ids
    gap_ids=$(echo "$title" | grep -oE '[A-Z]+-[0-9]+' | sort -u || true)
    if [ -z "$gap_ids" ]; then
        [ "$QUIET" -eq 0 ] && echo "[drift] PR #$pr [SKIP: no gap-ID in title] — $title"
        return 0
    fi

    body=$(gh pr view "$pr" --json body -q .body 2>/dev/null || true)
    local files diff
    files=$(gh pr view "$pr" --json files -q '.files[].path' 2>/dev/null || true)
    diff=$(gh pr diff "$pr" 2>/dev/null || true)

    local clean=1
    for gap_id in $gap_ids; do
        # Search for gap-ID in body, file paths, or diff content.
        if echo "$body"  | grep -qF "$gap_id" 2>/dev/null \
        || echo "$files" | grep -qF "$gap_id" 2>/dev/null \
        || echo "$diff"  | grep -qF "$gap_id" 2>/dev/null; then
            continue  # found — no drift for this ID
        fi
        # Drift: title claims gap_id but no signature of it.
        clean=0
        [ "$QUIET" -eq 0 ] && echo "[drift] PR #$pr DRIFT — title claims '$gap_id' but body/files/diff have no signature: $title"
        emit_alert "$pr" "$title" "$gap_id"
    done

    if [ "$clean" -eq 1 ] && [ "$QUIET" -eq 0 ]; then
        echo "[drift] PR #$pr [OK] — title gaps $gap_ids found in diff/body/files"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
if [ -n "$PR_NUMBER" ]; then
    check_one_pr "$PR_NUMBER"
elif [ "$RECENT" -gt 0 ]; then
    [ "$QUIET" -eq 0 ] && echo "[drift] scanning last $RECENT merged PRs..."
    while IFS= read -r pr; do
        [ -n "$pr" ] && check_one_pr "$pr"
    done < <(gh pr list --state merged --limit "$RECENT" --json number -q '.[].number')
else
    echo "usage: $0 <PR-NUMBER> | --recent N | --quiet" >&2
    exit 2
fi

exit 0
