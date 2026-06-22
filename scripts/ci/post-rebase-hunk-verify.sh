#!/usr/bin/env bash
# post-rebase-hunk-verify.sh — detect silent hunk drops after git rebase (INFRA-1526)
#
# Root cause was: src/main.rs had merge=rust-main-append in .gitattributes; the
# append-only driver silently discarded internal-edit hunks when the pure-append
# assumption failed. Fixed 2026-05-23 by removing the attribute. This script is
# the mitigation guard: it catches regressions + any similar future driver mis-config.
#
# Usage (called by bot-merge.sh after a successful rebase):
#   REMOTE=origin BASE_BRANCH=main GAP_ID=INFRA-NNNN bash post-rebase-hunk-verify.sh
#
# Environment:
#   REMOTE                      — git remote name (default: origin)
#   BASE_BRANCH                 — base branch (default: main)
#   GAP_ID                      — gap ID for ambient event correlation (default: unknown)
#   CHUMP_HUNK_VERIFY_THRESHOLD — min added-line count to flag a drop (default: 50)
#
# Exit codes:
#   0 — no drops detected (or ORIG_HEAD not set — safe to continue)
#   1 — at least one file with >THRESHOLD added lines before rebase has 0 after
#
# On drop, emits kind=rebase_hunk_dropped to .chump-locks/ambient.jsonl for each
# affected file so the operator is notified before the bad push reaches CI.
# scanner-anchor: "kind":"rebase_hunk_dropped"

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
AMBIENT="${REPO_ROOT}/.chump-locks/ambient.jsonl"
THRESHOLD="${CHUMP_HUNK_VERIFY_THRESHOLD:-50}"
REMOTE="${REMOTE:-origin}"
BASE_BRANCH="${BASE_BRANCH:-main}"
GAP_ID="${GAP_ID:-unknown}"

# ORIG_HEAD is written by git rebase on success; absent means no rebase ran.
if ! ORIG_HEAD=$(git rev-parse ORIG_HEAD 2>/dev/null); then
    printf '[hunk-verify] ORIG_HEAD not set — no rebase in progress, skipping.\n' >&2
    exit 0
fi

HEAD=$(git rev-parse HEAD)

# Find where the pre-rebase branch diverged from the base.
BEFORE_BASE=$(git merge-base "$ORIG_HEAD" "${REMOTE}/${BASE_BRANCH}" 2>/dev/null || true)
if [[ -z "$BEFORE_BASE" ]]; then
    printf '[hunk-verify] Cannot find merge-base for ORIG_HEAD — skipping.\n' >&2
    exit 0
fi

# Build per-file added-line maps.  Binary files report "-" for both counts; skip them.
declare -A before_added after_added

while IFS=$'\t' read -r added _deleted file; do
    [[ "$added" == "-" || -z "$file" ]] && continue
    before_added["$file"]="${added:-0}"
done < <(git diff --numstat "${BEFORE_BASE}..${ORIG_HEAD}" 2>/dev/null || true)

while IFS=$'\t' read -r added _deleted file; do
    [[ "$added" == "-" || -z "$file" ]] && continue
    after_added["$file"]="${added:-0}"
done < <(git diff --numstat "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null || true)

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
dropped=0

for file in "${!before_added[@]}"; do
    lines_before="${before_added[$file]}"
    lines_after="${after_added[$file]:-0}"

    if [[ "$lines_before" -gt "$THRESHOLD" && "$lines_after" -eq 0 ]]; then
        printf '[hunk-verify] HUNK DROP: %s — %d lines before rebase, 0 after\n' \
            "$file" "$lines_before" >&2
        dropped=1

        event=$(printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s","gap_id":"%s"}' \
            "$ts" "$file" "$lines_before" "$ORIG_HEAD" "$HEAD" "$GAP_ID")
        printf '%s\n' "$event" >> "$AMBIENT" 2>/dev/null || true
    fi
done

if [[ "$dropped" -eq 1 ]]; then
    printf '[hunk-verify] FAIL — rebase silently dropped hunks from one or more files.\n' >&2
    printf '[hunk-verify] Inspect: git diff --stat %s..ORIG_HEAD vs %s/%s..HEAD\n' \
        "$BEFORE_BASE" "$REMOTE" "$BASE_BRANCH" >&2
    printf '[hunk-verify] kind=rebase_hunk_dropped emitted to ambient.jsonl for each affected file.\n' >&2
    exit 1
fi

printf '[hunk-verify] OK — no hunk drops detected (threshold=%d lines, files checked=%d).\n' \
    "$THRESHOLD" "${#before_added[@]}" >&2
exit 0
