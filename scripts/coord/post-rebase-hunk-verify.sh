#!/usr/bin/env bash
# scripts/coord/post-rebase-hunk-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop guard. After a successful git rebase, ORIG_HEAD
# points to the pre-rebase branch tip. This script compares per-file
# addition counts between the original commits and the rebased commits.
# If any file had ≥ MIN_LINES added in the original but 0 in the rebased
# result, it emits kind=rebase_hunk_dropped and exits 1, blocking the push.
#
# Root cause (INFRA-1526): merge-driver-append-only.sh dedup compared lines
# against the full $OURS file (including shared ancestor prefix). Common
# structural lines like `}` and blank lines matched identical lines in the
# ancestor prefix and were silently dropped from theirs_tail. PR #2216 lost
# a 173-line src/main.rs block this way.
#
# Usage (called from bot-merge.sh and chump-rebase-and-push.sh):
#   bash scripts/coord/post-rebase-hunk-verify.sh [--emit-ambient] [--min-lines N]
#
# Exit codes:
#   0  safe — no hunk drops detected
#   1  hunk drop detected — push blocked; rebase manually and inspect
#   2  precondition not met (ORIG_HEAD absent, no merge-base) — check skipped
#
# Env:
#   CHUMP_REBASE_VERIFY_MIN_LINES  files with fewer added lines are ignored (default 50)
#   CHUMP_AMBIENT_LOG              ambient.jsonl path (auto-detected)
#   BASE_BRANCH                    branch we rebased onto (default: main)
#   CHUMP_REPO_ROOT                override repo root (used in tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
    || (cd "$SCRIPT_DIR/../.." && pwd))}"

MIN_LINES="${CHUMP_REBASE_VERIFY_MIN_LINES:-50}"
BASE_BRANCH="${BASE_BRANCH:-main}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
EMIT_AMBIENT=0

for _arg in "$@"; do
    case "$_arg" in
    --emit-ambient)    EMIT_AMBIENT=1 ;;
    --min-lines=*)     MIN_LINES="${_arg#*=}" ;;
    esac
done

# ORIG_HEAD is set by git rebase. Absent means no rebase occurred this session.
if ! git -C "$REPO_ROOT" rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
    echo "[hunk-verify] ORIG_HEAD not set — no rebase in flight, skipping" >&2
    exit 2
fi

ORIG_HEAD="$(git -C "$REPO_ROOT" rev-parse ORIG_HEAD)"
CUR_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# If branch was already up-to-date, nothing changed.
if [[ "$ORIG_HEAD" == "$CUR_HEAD" ]]; then
    echo "[hunk-verify] HEAD unchanged after rebase — nothing to verify" >&2
    exit 0
fi

# Divergence point of the ORIGINAL branch vs the rebase target.
OLD_BASE="$(git -C "$REPO_ROOT" merge-base "$ORIG_HEAD" "origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$REPO_ROOT" merge-base "$ORIG_HEAD" "$BASE_BRANCH" 2>/dev/null \
    || true)"

# Divergence point of the REBASED branch vs the rebase target.
NEW_BASE="$(git -C "$REPO_ROOT" merge-base "$CUR_HEAD" "origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$REPO_ROOT" merge-base "$CUR_HEAD" "$BASE_BRANCH" 2>/dev/null \
    || true)"

if [[ -z "$OLD_BASE" || -z "$NEW_BASE" ]]; then
    echo "[hunk-verify] cannot determine merge-base — skipping (no origin/$BASE_BRANCH?)" >&2
    exit 2
fi

# git diff --numstat emits: <added>\t<deleted>\t<path>
_stat() { git -C "$REPO_ROOT" diff --numstat "$1" "$2" 2>/dev/null || true; }

ORIG_STAT="$(_stat "$OLD_BASE" "$ORIG_HEAD")"
REBASED_STAT="$(_stat "$NEW_BASE" "$CUR_HEAD")"

if [[ -z "$ORIG_STAT" ]]; then
    echo "[hunk-verify] no file changes between $OLD_BASE and $ORIG_HEAD — nothing to verify" >&2
    exit 0
fi

DROPPED=0
FOUND_FILES=""

while IFS=$'\t' read -r orig_adds _dels file; do
    [[ -z "$file" ]] && continue
    # Skip binary files (numstat shows "-" for binaries).
    [[ "$orig_adds" == "-" ]] && continue
    [[ "${orig_adds}" =~ ^[0-9]+$ ]] || continue
    [[ "$orig_adds" -lt "$MIN_LINES" ]] && continue

    rebased_adds="$(printf '%s' "$REBASED_STAT" \
        | awk -F'\t' -v f="$file" '$3 == f {print $1; exit}')"
    rebased_adds="${rebased_adds:-0}"
    [[ "${rebased_adds}" =~ ^[0-9]+$ ]] || rebased_adds=0

    if [[ "$rebased_adds" -eq 0 ]]; then
        DROPPED=$((DROPPED + 1))
        FOUND_FILES="${FOUND_FILES}  $file  (+${orig_adds} → 0 lines)\n"

        if [[ "$EMIT_AMBIENT" -eq 1 ]]; then
            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            # scanner-anchor: "kind":"rebase_hunk_dropped"
            printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s"}\n' \
                "$_ts" "$file" "$orig_adds" "$ORIG_HEAD" "$CUR_HEAD" \
                >> "$AMBIENT" 2>/dev/null || true
        fi
    fi
done <<< "$ORIG_STAT"

if [[ "$DROPPED" -gt 0 ]]; then
    echo "[hunk-verify] FAIL — $DROPPED file(s) silently lost ≥${MIN_LINES} lines after rebase:" >&2
    printf '%b' "$FOUND_FILES" >&2
    echo "[hunk-verify]  original tip: $ORIG_HEAD (base: $OLD_BASE)" >&2
    echo "[hunk-verify]   rebased tip: $CUR_HEAD (base: $NEW_BASE)" >&2
    echo "[hunk-verify] Inspect: git diff $OLD_BASE $ORIG_HEAD -- <file>" >&2
    echo "[hunk-verify] Re-run rebase manually and resolve any conflicts explicitly." >&2
    exit 1
fi

_file_count="$(printf '%s' "$ORIG_STAT" | grep -c '.' || echo 0)"
echo "[hunk-verify] OK — no hunk drops detected (${_file_count} file(s) checked, threshold ≥${MIN_LINES} lines)"
exit 0
