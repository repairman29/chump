#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector.
#
# After any automated rebase, verify no file with more than THRESHOLD added
# lines in the original commits has 0 lines in the rebased result.  This
# catches the class of silent data loss where a merge driver or -X strategy
# discards a file's content instead of producing conflict markers.
#
# Root cause history: src/main.rs had merge=rust-main-append which silently
# dropped content instead of marking conflicts (removed 2026-05-23 P0 fix).
# wedge-recover.sh used -X theirs which overwrote feature-branch hunks with
# main's version (fixed by INFRA-1526).  This script is the safety net that
# catches either pattern at the cheapest possible layer.
#
# Usage:
#   post-rebase-verify.sh [ORIG_HEAD_SHA]
#   ORIG_HEAD_SHA defaults to reading .git/ORIG_HEAD (set by git rebase).
#
# Environment:
#   CHUMP_REPO_ROOT               — repo root (default: git rev-parse --show-toplevel)
#   AMBIENT                       — path to ambient.jsonl for event emission
#   CHUMP_REBASE_VERIFY_THRESHOLD — min added-lines to flag a file (default: 50)
#   CHUMP_REBASE_VERIFY_SKIP=1    — bypass (emits skip message, exits 0)
#
# Exit codes:
#   0 — clean (no drops detected, or skipped)
#   1 — one or more files lost all additions after rebase
#   2 — usage / environment error

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
THRESHOLD="${CHUMP_REBASE_VERIFY_THRESHOLD:-50}"

if [[ "${CHUMP_REBASE_VERIFY_SKIP:-0}" == "1" ]]; then
    echo "[post-rebase-verify] SKIP: CHUMP_REBASE_VERIFY_SKIP=1"
    exit 0
fi

# ── Resolve ORIG_HEAD ─────────────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
    ORIG_HEAD_SHA="$1"
else
    GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"
    ORIG_HEAD_FILE="${GIT_DIR}/ORIG_HEAD"
    if [[ -f "$ORIG_HEAD_FILE" ]]; then
        ORIG_HEAD_SHA="$(cat "$ORIG_HEAD_FILE")"
    else
        echo "[post-rebase-verify] SKIP: .git/ORIG_HEAD not found (not a post-rebase state)"
        exit 0
    fi
fi

if ! git rev-parse --verify "${ORIG_HEAD_SHA}^{commit}" >/dev/null 2>&1; then
    echo "[post-rebase-verify] ERROR: '${ORIG_HEAD_SHA}' is not a valid commit"
    exit 2
fi

HEAD_SHA="$(git rev-parse HEAD)"

if [[ "$ORIG_HEAD_SHA" == "$HEAD_SHA" ]]; then
    echo "[post-rebase-verify] SKIP: HEAD unchanged — rebase was a no-op"
    exit 0
fi

# ── Compute diff bases ────────────────────────────────────────────────────────
# The merge-base before the rebase: where our branch diverged from main.
ORIG_BASE="$(git merge-base "$ORIG_HEAD_SHA" origin/main 2>/dev/null || true)"
if [[ -z "$ORIG_BASE" ]]; then
    echo "[post-rebase-verify] SKIP: cannot compute merge-base (detached HEAD or shallow clone)"
    exit 0
fi

NEW_BASE="$(git merge-base origin/main HEAD 2>/dev/null || echo "origin/main")"

# ── Collect file stats using temp files (bash 3 compatible, no declare -A) ───
ORIG_STATS="$(mktemp -t prv-orig-XXXXXX)"
NEW_STATS="$(mktemp -t prv-new-XXXXXX)"
trap 'rm -f "$ORIG_STATS" "$NEW_STATS"' EXIT

# Format: "<added_lines>\t<file_path>"  (only files with >THRESHOLD additions)
git diff --numstat "$ORIG_BASE" "$ORIG_HEAD_SHA" 2>/dev/null \
    | awk -v thr="$THRESHOLD" -F'\t' '
        $1 != "-" && $1+0 > thr { printf "%s\t%s\n", $1, $3 }
    ' > "$ORIG_STATS"

if [[ ! -s "$ORIG_STATS" ]]; then
    echo "[post-rebase-verify] OK: no files with >${THRESHOLD} added lines in original commits"
    exit 0
fi

# Format: "<file_path>" — one per line of files that have >0 additions in rebase
git diff --numstat "$NEW_BASE" HEAD 2>/dev/null \
    | awk -F'\t' '$1 != "-" && $1+0 > 0 { print $3 }' > "$NEW_STATS"

# ── Detect drops ─────────────────────────────────────────────────────────────
DROPS=0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

while IFS=$'\t' read -r orig_lines file; do
    # Check if this file appears in the rebased stats
    if ! grep -qxF "$file" "$NEW_STATS" 2>/dev/null; then
        echo "[post-rebase-verify] HUNK DROP: $file — had ${orig_lines} added lines originally, 0 after rebase"
        DROPS=$((DROPS + 1))

        # Escape file path for JSON (backslash then double-quote)
        file_escaped="$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')"

        printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%s,"original_commit":"%s","rebased_commit":"%s"}\n' \
            "$TS" "$file_escaped" "$orig_lines" "$ORIG_HEAD_SHA" "$HEAD_SHA" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
done < "$ORIG_STATS"

if [[ $DROPS -gt 0 ]]; then
    echo "[post-rebase-verify] FAIL: ${DROPS} file(s) lost all additions after rebase"
    echo "  Likely cause: merge driver with silent-discard or rebase -X theirs strategy."
    echo "  Check .gitattributes for custom merge= drivers on affected files."
    exit 1
fi

# Count surviving files for the OK message
orig_count="$(wc -l < "$ORIG_STATS" | tr -d ' ')"
echo "[post-rebase-verify] OK: all ${orig_count} large-file(s) survived rebase"
exit 0
