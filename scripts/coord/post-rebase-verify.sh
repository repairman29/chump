#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector.
#
# After `git rebase`, ORIG_HEAD points to where HEAD was before the rebase.
# This script compares per-file added-line counts between the original branch
# commits and the rebased commits. If any file contributed >50 added lines in
# the original but has 0 added lines after the rebase, the rebase silently
# dropped those hunks — emit kind=rebase_hunk_dropped and exit 1.
#
# Root cause (INFRA-1526): the rust-main-append merge driver's pure-append
# check returned exit 1 (fallback signal), but git's rebase fallback path
# silently discarded hunks near the conflict boundary instead of producing
# conflict markers. Fix: .gitattributes removed src/main.rs from the driver
# (2026-05-23 P0 fix) and install-merge-drivers.sh no longer registers it.
# This script is the post-rebase safety net that catches any recurrence.
#
# Usage (typically called by rebase scripts, not directly):
#   bash scripts/coord/post-rebase-verify.sh [--base <ref>] [--orig-head <sha>]
#                                             [--threshold <N>] [--dry-run]
#
# Options:
#   --base <ref>         Base ref the rebase landed on. Default: origin/main
#   --orig-head <sha>    Override ORIG_HEAD (useful when called from a temp
#                        worktree where ORIG_HEAD may not exist). Default: ORIG_HEAD
#   --threshold <N>      Min added lines in original to flag a drop. Default: 50
#   --dry-run            Print findings without emitting events or exiting 1
#
# Exit codes:
#   0  clean — no hunk drops detected
#   1  one or more files had hunks silently dropped
#   2  usage/env error (not in a git repo, ORIG_HEAD missing, etc.)
#
# Emits kind=rebase_hunk_dropped per dropped file:
#   {"ts":"...","kind":"rebase_hunk_dropped","file":"src/main.rs",
#    "lines_dropped":173,"original_commit":"<sha>","rebased_commit":"<sha>"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"

AMBIENT_LIB="${SCRIPT_DIR}/lib/ambient-write.sh"
if [[ -f "$AMBIENT_LIB" ]]; then
    # shellcheck source=scripts/coord/lib/ambient-write.sh disable=SC1091
    source "$AMBIENT_LIB"
else
    _ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }
fi

BASE_REF="origin/main"
ORIG_HEAD_OVERRIDE=""
THRESHOLD=50
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)        BASE_REF="$2";           shift 2 ;;
        --base=*)      BASE_REF="${1#*=}";       shift ;;
        --orig-head)   ORIG_HEAD_OVERRIDE="$2";  shift 2 ;;
        --orig-head=*) ORIG_HEAD_OVERRIDE="${1#*=}"; shift ;;
        --threshold)   THRESHOLD="$2";           shift 2 ;;
        --threshold=*) THRESHOLD="${1#*=}";      shift ;;
        --dry-run)     DRY_RUN=1;                shift ;;
        *) printf '[post-rebase-verify] unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf '[post-rebase-verify] not in a git repo\n' >&2
    exit 2
fi

# Resolve ORIG_HEAD — set by git after a rebase.
if [[ -n "$ORIG_HEAD_OVERRIDE" ]]; then
    ORIG_HEAD="$ORIG_HEAD_OVERRIDE"
elif ORIG_HEAD="$(git -C "$REPO_ROOT" rev-parse ORIG_HEAD 2>/dev/null)"; then
    :
else
    printf '[post-rebase-verify] ORIG_HEAD not set — was a rebase just run?\n' >&2
    exit 2
fi

REBASED_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"

# Merge base of the original branch tip with the rebase target.
PRE_REBASE_BASE="$(git -C "$REPO_ROOT" merge-base "$ORIG_HEAD" "$BASE_REF" 2>/dev/null || true)"
if [[ -z "$PRE_REBASE_BASE" ]]; then
    printf '[post-rebase-verify] could not compute merge-base of ORIG_HEAD and %s\n' "$BASE_REF" >&2
    exit 2
fi

# --numstat output: <added>\t<deleted>\t<filename>
# Use --diff-filter=AM to skip pure deletions (they can legitimately go to 0).
_numstat_before="$(git -C "$REPO_ROOT" diff --numstat --diff-filter=AM \
    "${PRE_REBASE_BASE}..${ORIG_HEAD}" 2>/dev/null || true)"

_numstat_after="$(git -C "$REPO_ROOT" diff --numstat --diff-filter=AM \
    "${BASE_REF}..${REBASED_HEAD}" 2>/dev/null || true)"

if [[ -z "$_numstat_before" ]]; then
    printf '[post-rebase-verify] no modified/added files in original branch — nothing to verify\n'
    exit 0
fi

# Lookup helper: given a filename, return its added-line count from _numstat_after.
# Uses awk so we don't need bash 4 associative arrays (macOS ships bash 3.2).
_after_added_for() {
    local file="$1"
    printf '%s\n' "$_numstat_after" | awk -v f="$file" -F'\t' '
        $3 == f && $1 ~ /^[0-9]+$/ { print $1; found=1; exit }
        END { if (!found) print 0 }
    '
}

DROPS=0
DROPPED_FILES=""

while IFS=$'\t' read -r added _deleted file; do
    [[ "$added" =~ ^[0-9]+$ ]] || continue
    if (( added <= THRESHOLD )); then
        continue
    fi
    after="$(_after_added_for "$file")"
    if (( after == 0 )); then
        DROPS=$((DROPS + 1))
        DROPPED_FILES="${DROPPED_FILES}  ${file} (original +${added} lines → rebased +${after})\n"
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        event="$(printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s"}' \
            "$ts" "$file" "$added" "$ORIG_HEAD" "$REBASED_HEAD")"
        if (( DRY_RUN == 0 )); then
            _ambient_write "$AMBIENT_LOG" "$event"
        else
            printf '[post-rebase-verify] DRY-RUN event: %s\n' "$event"
        fi
    fi
done <<< "$_numstat_before"

if (( DROPS > 0 )); then
    printf '[post-rebase-verify] FAIL — %d file(s) had hunks silently dropped by rebase:\n' "$DROPS" >&2
    printf '%b' "$DROPPED_FILES" >&2
    printf '[post-rebase-verify] ORIG_HEAD=%s  rebased=%s  base=%s\n' \
        "$ORIG_HEAD" "$REBASED_HEAD" "$BASE_REF" >&2
    printf '[post-rebase-verify] Emitted kind=rebase_hunk_dropped for each dropped file.\n' >&2
    printf '[post-rebase-verify] To diagnose: git diff %s..%s -- <file>\n' \
        "$PRE_REBASE_BASE" "$ORIG_HEAD" >&2
    if (( DRY_RUN == 0 )); then
        exit 1
    fi
else
    printf '[post-rebase-verify] OK — no hunk drops detected (%d files checked, threshold=%d)\n' \
        "$(wc -l <<< "$_numstat_before" | tr -d ' ')" "$THRESHOLD"
fi

exit 0
