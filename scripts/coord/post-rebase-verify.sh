#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector. Run immediately after a successful
# 'git rebase origin/main' to catch silent data loss before push.
#
# Compares per-file line-change stats between the original commits
# (ORIG_BASE..ORIG_HEAD) and the rebased result (origin/main..HEAD).
# If any file had >THRESHOLD added lines in the original and has zero
# lines in the rebased result, emits kind=rebase_hunk_dropped and
# exits 1 — stopping the push.
#
# Usage:
#   scripts/coord/post-rebase-verify.sh [--orig SHA] [--base REMOTE/BRANCH]
#
#   --orig  pre-rebase tip (default: git rev-parse ORIG_HEAD)
#   --base  base branch ref (default: origin/main)
#
# Exit codes:
#   0 — all original files present in rebased result (safe to push)
#   1 — hunk drop detected (ambient event emitted; abort push)
#   2 — skipped (ORIG_HEAD unavailable or no stats to compare)
#
# Bypass: CHUMP_SKIP_POST_REBASE_VERIFY=1 → exit 0 + emit bypass event.
# scanner-anchor: "kind":"rebase_hunk_dropped"

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
MIN_LINES="${CHUMP_REBASE_VERIFY_MIN_LINES:-50}"

ORIG_HEAD_ARG=""
BASE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --orig) shift; ORIG_HEAD_ARG="$1" ;;
        --orig=*) ORIG_HEAD_ARG="${1#*=}" ;;
        --base) shift; BASE_ARG="$1" ;;
        --base=*) BASE_ARG="${1#*=}" ;;
        --help|-h)
            head -25 "$0" | grep '^#' | sed 's/^# //; s/^#//'
            exit 0
            ;;
    esac
    shift
done

if [[ "${CHUMP_SKIP_POST_REBASE_VERIFY:-0}" == "1" ]]; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","kind":"post_rebase_verify_bypassed","reason":"CHUMP_SKIP_POST_REBASE_VERIFY=1"}\n' \
        "$ts" >> "$AMBIENT" 2>/dev/null || true
    echo "[post-rebase-verify] BYPASS: CHUMP_SKIP_POST_REBASE_VERIFY=1"
    exit 0
fi

# ── Resolve refs ─────────────────────────────────────────────────────────────

ORIG_HEAD="${ORIG_HEAD_ARG:-$(git rev-parse ORIG_HEAD 2>/dev/null || echo "")}"
if [[ -z "$ORIG_HEAD" ]]; then
    echo "[post-rebase-verify] ORIG_HEAD not available — no recent rebase, skipping" >&2
    exit 2
fi

HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ -z "$HEAD" ]]; then
    echo "[post-rebase-verify] cannot resolve HEAD" >&2
    exit 2
fi

# Resolve base branch ref
if [[ -n "$BASE_ARG" ]]; then
    BASE=$(git rev-parse --verify "$BASE_ARG" 2>/dev/null || echo "")
else
    BASE=$(git rev-parse --verify origin/main 2>/dev/null \
        || git rev-parse --verify origin/master 2>/dev/null \
        || echo "")
fi
if [[ -z "$BASE" ]]; then
    echo "[post-rebase-verify] cannot resolve base branch — skipping" >&2
    exit 2
fi

# Original merge-base: where the branch diverged from main before rebase
ORIG_BASE=$(git merge-base "$ORIG_HEAD" "$BASE" 2>/dev/null || echo "")
if [[ -z "$ORIG_BASE" ]]; then
    echo "[post-rebase-verify] cannot compute original merge-base — skipping" >&2
    exit 2
fi

# Guard: if ORIG_HEAD == ORIG_BASE, branch had nothing on it; nothing to check
if [[ "$ORIG_HEAD" == "$ORIG_BASE" ]]; then
    echo "[post-rebase-verify] original branch was empty relative to base — skipping" >&2
    exit 2
fi

# ── Extract per-file addition counts from git log --stat output ───────────────
# git log --stat lines containing file stats look like:
#   " src/main.rs                   | 173 +++++++++++...---"
# We capture the total change count (insertions + deletions combined per line).
# We care about presence/absence, not direction — a file that had 173 changes
# and ended up with 0 changes in the rebase is a silent drop.

parse_stat_into_assoc() {
    local start="$1" end="$2"
    local -n _out="$3"
    while IFS= read -r line; do
        # Match "  path/to/file  | NNN" — tolerate arrow paths (renames)
        if [[ "$line" =~ ^[[:space:]]+(.+)[[:space:]]+\|[[:space:]]+([0-9]+) ]]; then
            local f="${BASH_REMATCH[1]}"
            local n="${BASH_REMATCH[2]}"
            # Trim leading/trailing whitespace from filename
            f="${f#"${f%%[! ]*}"}"
            f="${f%"${f##*[! ]}"}"
            # Strip rename arrow "a => b" → use destination
            if [[ "$f" == *" => "* ]]; then
                f="${f##*=> }"
                f="${f%\}}"
                f="${f#\{}"
            fi
            _out["$f"]=$(( ${_out["$f"]:-0} + n ))
        fi
    done < <(git log --stat "${start}..${end}" 2>/dev/null)
}

declare -A orig_stats
parse_stat_into_assoc "$ORIG_BASE" "$ORIG_HEAD" orig_stats

if [[ ${#orig_stats[@]} -eq 0 ]]; then
    echo "[post-rebase-verify] original commits have no file stats — skipping" >&2
    exit 2
fi

declare -A rebased_stats
parse_stat_into_assoc "$BASE" "$HEAD" rebased_stats

# ── Detect drops ─────────────────────────────────────────────────────────────

drops=()
for file in "${!orig_stats[@]}"; do
    orig_n="${orig_stats[$file]}"
    rebased_n="${rebased_stats[$file]:-0}"
    if (( orig_n > MIN_LINES && rebased_n == 0 )); then
        drops+=("$file:$orig_n")
        echo "[post-rebase-verify] HUNK DROP: '$file' had $orig_n changed lines in original; 0 in rebased result" >&2
    fi
done

if [[ ${#drops[@]} -eq 0 ]]; then
    echo "[post-rebase-verify] OK — all original files (>${MIN_LINES} lines) present in rebased result"
    exit 0
fi

# ── Emit ambient events and fail ─────────────────────────────────────────────

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for entry in "${drops[@]}"; do
    file="${entry%%:*}"
    lines="${entry##*:}"
    printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%s,"original_commit":"%s","rebased_commit":"%s"}\n' \
        "$ts" "$file" "$lines" "${ORIG_HEAD:0:12}" "${HEAD:0:12}" \
        >> "$AMBIENT" 2>/dev/null || true
done

echo "[post-rebase-verify] ERROR: ${#drops[@]} file(s) silently dropped — push aborted. Fix or set CHUMP_SKIP_POST_REBASE_VERIFY=1 with a bypass trailer." >&2
exit 1
