#!/usr/bin/env bash
# scripts/coord/close-superseded-prs.sh — INFRA-994 (2026-05-14)
#
# After `chump gap ship <GAP-ID>` marks a gap done, this helper finds any
# remaining open PRs whose title contains the gap ID and closes them with an
# explanatory comment — unless the PR has unique commits not already in main
# (false-positive guard).
#
# Usage:
#   close-superseded-prs.sh <GAP-ID>
#   close-superseded-prs.sh <GAP-ID> --dry-run
#
# Environment:
#   CHUMP_LOCK_DIR   — override path to .chump-locks/ (for tests)
#   GH_TOKEN / GITHUB_TOKEN — GitHub auth (falls back to gh keyring)
#
# Emits kind=pr_auto_closed_superseded to ambient.jsonl for each closure.
#
# Exit codes:
#   0 — success (including when there are no orphaned PRs to close)
#   1 — usage error

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/repo-paths.sh
# shellcheck disable=SC1091  # repo-paths.sh sourced at runtime; not available to shellcheck
source "$SCRIPT_DIR/../lib/repo-paths.sh"

GAP_ID="${1:-}"
if [[ -z "$GAP_ID" ]]; then
    echo "Usage: close-superseded-prs.sh <GAP-ID> [--dry-run]" >&2
    exit 1
fi

DRY_RUN=0
for arg in "${@:2}"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

AMBIENT="$LOCK_DIR/ambient.jsonl"

# ── Helper: emit ambient event ────────────────────────────────────────────────
_emit_pr_auto_closed() {
    local pr_num="$1" pr_title="$2" closed_pr_ref="$3"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"pr_auto_closed_superseded","gap_id":"%s","pr":%s,"title":"%s","merged_via":"%s"}\n' \
        "$ts" "$GAP_ID" "$pr_num" \
        "$(printf '%s' "$pr_title" | sed 's/"/\\"/g')" \
        "$closed_pr_ref" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Resolve repo (owner/name) ─────────────────────────────────────────────────
REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
if [[ -z "$REPO" ]]; then
    echo "[close-superseded-prs] WARN: cannot resolve GitHub repo from remote; skipping." >&2
    exit 0
fi

# ── Find open PRs whose title contains the gap ID ────────────────────────────
# Use REST to avoid GraphQL rate limits.
# We search all open PRs — gh api pagination returns up to 100 per page; we
# filter client-side for safety.
OPEN_PRS_JSON="$(gh api "repos/$REPO/pulls?state=open&per_page=100" \
    --jq "[.[] | select(.title | contains(\"$GAP_ID\")) | {number: .number, title: .title, head_ref: .head.ref}]" 2>/dev/null)" || {
    echo "[close-superseded-prs] WARN: gh api call failed; skipping orphan close for $GAP_ID." >&2
    exit 0
}

if [[ -z "$OPEN_PRS_JSON" || "$OPEN_PRS_JSON" == "[]" ]]; then
    echo "[close-superseded-prs] No open PRs found for $GAP_ID — nothing to close."
    exit 0
fi

PR_COUNT="$(printf '%s' "$OPEN_PRS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")"
echo "[close-superseded-prs] Found $PR_COUNT open PR(s) for $GAP_ID."

# ── Find the merged commit for this gap (for the close comment) ───────────────
# INFRA-1289: MERGED_SHA is now also a gate — if empty, the close is forbidden
# (gap not yet visible on main; would be a false-positive close).
MERGED_SHA="$(git -C "$REPO_ROOT" log origin/main --oneline --grep="$GAP_ID" --format="%H" \
    2>/dev/null | head -1 || true)"

# ── Process each orphaned PR ──────────────────────────────────────────────────
# Use process substitution instead of heredoc-pipe (shellcheck SC1121).
_pr_lines=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
for pr in data:
    print(str(pr['number']) + '|' + pr['head_ref'] + '|' + pr['title'])
" "$OPEN_PRS_JSON" 2>/dev/null || true)

while IFS='|' read -r pr_num head_ref pr_title; do
    echo "[close-superseded-prs] Checking PR #$pr_num ($head_ref): '$pr_title'"

    # ── False-positive guard ─────────────────────────────────────────────────
    # Fetch the remote branch so git cherry can compare.
    git -C "$REPO_ROOT" fetch origin "$head_ref" --quiet 2>/dev/null || {
        echo "[close-superseded-prs]   WARN: cannot fetch branch '$head_ref'; skipping PR #$pr_num." >&2
        continue
    }

    # git cherry lists commits in <branch> that are NOT in <upstream>.
    # A '+' line means a unique commit not in main; a '-' means an
    # equivalent patch (same diff) already applied.
    UNIQUE="$(git -C "$REPO_ROOT" cherry origin/main "FETCH_HEAD" 2>/dev/null \
        | grep -c '^+' || echo 0)"

    if [[ "$UNIQUE" -gt 0 ]]; then
        echo "[close-superseded-prs]   SKIP PR #$pr_num — has $UNIQUE unique commit(s) not in main (false-positive guard)."
        continue
    fi

    # ── INFRA-1289: require git evidence before closing ──────────────────────
    # status=done alone is insufficient — gap ship can be called before the
    # implementing PR merges, causing false-positive closes. We require a
    # commit on main that references the gap ID. Without it, emit
    # orphan_pr_close_evidence_missing and skip — let operator decide.
    if [[ -z "$MERGED_SHA" ]]; then
        echo "[close-superseded-prs]   SKIP PR #$pr_num — gap $GAP_ID status=done but no commit on origin/main references it (evidence missing; INFRA-1289)." >&2
        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"orphan_pr_close_evidence_missing","gap_id":"%s","pr":%s,"reason":"status=done but no main commit found","source":"close-superseded-prs"}\n' \
            "$_ts" "$GAP_ID" "$pr_num" >> "$AMBIENT" 2>/dev/null || true
        continue
    fi

    # ── Build close comment ──────────────────────────────────────────────────
    CLOSE_COMMENT="Superseded: gap $GAP_ID was shipped via commit $MERGED_SHA on main. Closing this PR as no longer needed (all unique changes are already in main)."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[close-superseded-prs]   DRY-RUN: would close PR #$pr_num with comment: '$CLOSE_COMMENT'"
        continue
    fi

    # ── Close the PR ─────────────────────────────────────────────────────────
    # 1. Post close comment
    gh api "repos/$REPO/issues/$pr_num/comments" \
        -X POST -f body="$CLOSE_COMMENT" --silent 2>/dev/null || \
        echo "[close-superseded-prs]   WARN: failed to post comment on PR #$pr_num." >&2

    # 2. Close the PR via REST PATCH
    CLOSE_RC=0
    gh api "repos/$REPO/pulls/$pr_num" \
        -X PATCH -f state=closed --silent 2>/dev/null || CLOSE_RC=$?

    if [[ "$CLOSE_RC" -eq 0 ]]; then
        echo "[close-superseded-prs]   Closed PR #$pr_num (superseded by $GAP_ID ship)."
        _emit_pr_auto_closed "$pr_num" "$pr_title" "${MERGED_SHA:-direct-commit}"
    else
        echo "[close-superseded-prs]   WARN: failed to close PR #$pr_num (rc=$CLOSE_RC)." >&2
    fi
done <<< "$_pr_lines"

echo "[close-superseded-prs] Done."
