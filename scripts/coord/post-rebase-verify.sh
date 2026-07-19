#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector. Call immediately after a successful
# `git rebase origin/main` (before push). Compares the cumulative diff
# of the original commits (ORIG_HEAD..fork-point) against the rebased
# commits (origin/main..HEAD). If any file had >50 added lines in the
# original stack and now has 0 lines touched, it was silently dropped.
#
# Root cause history: the rust-main-append merge driver (append-only
# strategy on src/main.rs) silently discarded internal edits when the
# pure-append pre-check failed — instead of producing conflict markers
# it fell back to standard 3-way but dropped content near conflict
# boundaries. Removing the driver from .gitattributes (2026-05-23)
# fixed the silent-drop for that file; this script catches any future
# regression across ALL files.
#
# Usage:
#   bash scripts/coord/post-rebase-verify.sh [ORIG_HEAD]
#
#   ORIG_HEAD defaults to reading .git/ORIG_HEAD (set automatically by git).
#   Run from inside the worktree. Works in any git worktree.
#
# Environment:
#   CHUMP_AMBIENT     path to ambient.jsonl (defaults to .chump-locks/ambient.jsonl
#                     relative to repo root)
#   CHUMP_HUNK_DROP_THRESHOLD  min added-lines in original commit to flag
#                     (default: 50)
#
# Exit codes:
#   0 — no drops detected (or skip conditions met)
#   1 — one or more files with hunk drops detected; events emitted
#   2 — usage / git state error (ORIG_HEAD not found, not in a git repo)
#
# No env bypass on purpose: the EFFECTIVE-094 bypass-var ceiling ratchets
# down; callers that must skip verification simply don't invoke this script.

set -uo pipefail

# ── Locate repo root ──────────────────────────────────────────────────────────
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "[post-rebase-verify] ERROR: not inside a git repository" >&2
    exit 2
fi

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"
AMBIENT="${CHUMP_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
THRESHOLD="${CHUMP_HUNK_DROP_THRESHOLD:-50}"
mkdir -p "$(dirname "$AMBIENT")"

emit() {
    local kind="$1"; shift
    local fields="$1"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$fields" >> "$AMBIENT"
}

# ── Resolve ORIG_HEAD ─────────────────────────────────────────────────────────
ORIG_HEAD="${1:-}"
if [[ -z "$ORIG_HEAD" ]]; then
    ORIG_HEAD_FILE="$GIT_DIR/ORIG_HEAD"
    if [[ ! -f "$ORIG_HEAD_FILE" ]]; then
        echo "[post-rebase-verify] ORIG_HEAD not found — not after a rebase? Skipping." >&2
        exit 0
    fi
    ORIG_HEAD="$(cat "$ORIG_HEAD_FILE")"
fi

# Validate it resolves
if ! git rev-parse --quiet --verify "$ORIG_HEAD^{commit}" >/dev/null 2>&1; then
    echo "[post-rebase-verify] ERROR: ORIG_HEAD '$ORIG_HEAD' does not resolve to a commit" >&2
    exit 2
fi

# ── Compute old merge-base (fork point before rebase) ────────────────────────
# After `git rebase origin/main`:
#   - ORIG_HEAD = old branch tip
#   - origin/main = new base we rebased onto
#   - merge-base(ORIG_HEAD, origin/main) = fork point before the rebase
OLD_BASE="$(git merge-base "$ORIG_HEAD" origin/main 2>/dev/null || true)"
if [[ -z "$OLD_BASE" ]]; then
    echo "[post-rebase-verify] WARN: could not compute merge-base; skipping" >&2
    exit 0
fi

# ── Get numstats for original vs rebased stacks ──────────────────────────────
# Format from --numstat: "added\tdeleted\tfilename"
ORIG_STATS="$(git diff --numstat "$OLD_BASE..$ORIG_HEAD" 2>/dev/null || true)"
NEW_STATS="$(git diff --numstat "origin/main..HEAD" 2>/dev/null || true)"

if [[ -z "$ORIG_STATS" ]]; then
    echo "[post-rebase-verify] original stack is empty — nothing to verify"
    exit 0
fi

# ── Build set of files touched in rebased stack ───────────────────────────────
declare -A new_files
while IFS=$'\t' read -r _add _del fname; do
    [[ -z "$fname" ]] && continue
    new_files["$fname"]=1
done <<< "$NEW_STATS"

# ── Detect drops ─────────────────────────────────────────────────────────────
DROPS=0
ORIG_HEAD_SHORT="$(git rev-parse --short "$ORIG_HEAD" 2>/dev/null || echo "$ORIG_HEAD")"
HEAD_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo "HEAD")"

while IFS=$'\t' read -r added _deleted fname; do
    [[ -z "$fname" || -z "$added" ]] && continue
    # Skip binary files (git --numstat shows "-" for binaries)
    [[ "$added" == "-" ]] && continue
    if (( added > THRESHOLD )) && [[ -z "${new_files[$fname]+_}" ]]; then
        echo "[post-rebase-verify] HUNK DROP: $fname had +$added lines in original stack, 0 in rebased stack"
        emit "rebase_hunk_dropped" \
            "\"file\":\"$fname\",\"lines_dropped\":$added,\"original_commit\":\"$ORIG_HEAD_SHORT\",\"rebased_commit\":\"$HEAD_SHORT\",\"threshold\":$THRESHOLD"
        DROPS=$((DROPS + 1))
    fi
done <<< "$ORIG_STATS"

if (( DROPS > 0 )); then
    echo "[post-rebase-verify] FAIL — $DROPS file(s) with hunk drops detected (see ambient.jsonl for rebase_hunk_dropped events)" >&2
    echo "[post-rebase-verify] Likely cause: merge driver on one of the affected files discarded content." >&2
    echo "[post-rebase-verify] Check .gitattributes for merge= on: $(git diff --name-only "$OLD_BASE..$ORIG_HEAD" | head -5 | tr '\n' ' ')" >&2
    exit 1
fi

echo "[post-rebase-verify] OK — no hunk drops detected (checked $(wc -l <<< "$ORIG_STATS" | tr -d ' ') files, threshold=+$THRESHOLD)"
exit 0
