#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector. Compares per-file line-add counts between
# the original branch (pre-rebase) and the rebased branch. Emits
# kind=rebase_hunk_dropped if any file had >THRESHOLD added lines in the
# original commits but 0 in the rebased commits.
#
# Root cause this guards against: custom git merge drivers (e.g. the now-removed
# rust-main-append driver for src/main.rs, per .gitattributes 2026-05-23 P0 fix)
# silently discarding hunks during rebase instead of producing conflict markers.
#
# Call immediately after `git rebase` succeeds while git's ORIG_HEAD ref is set.
#
# Usage:
#   post-rebase-verify.sh [--orig-head <sha>] [--base <ref>] [--threshold <N>]
#                         [--dry-run]
#
# Arguments:
#   --orig-head <sha>   Pre-rebase branch tip. Default: git rev-parse ORIG_HEAD
#   --base <ref>        Base branch. Default: origin/main
#   --threshold <N>     Min added lines in original to flag. Default: 50
#   --dry-run           Print findings without emitting events or failing
#
# Exit codes:
#   0  no drops detected (or --dry-run)
#   1  fatal usage/git error
#   2  hunk drop detected — do NOT push; inspect and rework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"

AMBIENT_LIB="${SCRIPT_DIR}/lib/ambient-write.sh"
if [[ -f "$AMBIENT_LIB" ]]; then
    # shellcheck source=scripts/coord/lib/ambient-write.sh disable=SC1091
    source "$AMBIENT_LIB"
else
    _ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }
fi
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"

_tty() { [[ -t 2 ]]; }
red()  { _tty && printf '\033[0;31m%s\033[0m\n' "$*" >&2 || printf '%s\n' "$*" >&2; }
warn() { _tty && printf '\033[0;33m[prv] %s\033[0m\n' "$*" >&2 || printf '[prv] %s\n' "$*" >&2; }
info() { _tty && printf '\033[0;36m[prv]\033[0m %s\n' "$*" >&2 || printf '[prv] %s\n' "$*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────
ORIG_HEAD_ARG=""
BASE_REF="origin/main"
THRESHOLD=50
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --orig-head) ORIG_HEAD_ARG="$2"; shift 2 ;;
        --base)      BASE_REF="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        *) red "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Resolve ORIG_HEAD ─────────────────────────────────────────────────────────
if [[ -n "$ORIG_HEAD_ARG" ]]; then
    ORIG_HEAD="$ORIG_HEAD_ARG"
else
    ORIG_HEAD="$(git -C "$REPO_ROOT" rev-parse ORIG_HEAD 2>/dev/null || true)"
fi

if [[ -z "$ORIG_HEAD" ]]; then
    info "ORIG_HEAD not set — no rebase in flight, skipping verification."
    exit 0
fi

REBASED_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse "$BASE_REF" 2>/dev/null || true)"

if [[ -z "$BASE_SHA" ]]; then
    info "Cannot resolve base ref '$BASE_REF' — skipping verification."
    exit 0
fi

if [[ "$ORIG_HEAD" == "$REBASED_HEAD" ]]; then
    info "ORIG_HEAD == HEAD — branch not rebased (up to date), skipping."
    exit 0
fi

# ── Compute merge-bases ───────────────────────────────────────────────────────
ORIG_BASE="$(git -C "$REPO_ROOT" merge-base "$ORIG_HEAD" "$BASE_SHA" 2>/dev/null || true)"
if [[ -z "$ORIG_BASE" ]]; then
    info "Cannot compute merge-base for original branch — skipping."
    exit 0
fi

REBASED_BASE="$(git -C "$REPO_ROOT" merge-base "$REBASED_HEAD" "$BASE_SHA" 2>/dev/null || true)"
if [[ -z "$REBASED_BASE" ]]; then
    info "Cannot compute merge-base for rebased branch — skipping."
    exit 0
fi

info "post-rebase-verify: orig=$ORIG_HEAD rebased=$REBASED_HEAD threshold=$THRESHOLD"

# ── Collect per-file add counts via temp files ────────────────────────────────
# Uses temp files instead of associative arrays for bash 3.x compatibility.
# Format of each file: "<adds> <filename>" — one entry per file, sorted by filename.
_tmp_dir="$(mktemp -d)"
_tmp_orig="${_tmp_dir}/orig_adds.txt"
_tmp_rebased="${_tmp_dir}/rebased_adds.txt"
trap 'rm -rf "$_tmp_dir"' EXIT

# git --numstat: "<adds>\t<dels>\t<file>"  (binaries show "-\t-\t<file>")
# Sum adds per file across all commits in range, output "<adds> <file>" sorted by file.
_stat_adds() {
    local range="$1" out="$2"
    git -C "$REPO_ROOT" log --numstat --format="" "$range" 2>/dev/null \
        | awk 'NF==3 && $1~/^[0-9]+$/ { adds[$3]+=$1 }
               END { for (f in adds) print adds[f], f }' \
        | sort -k2 > "$out"
}

_stat_adds "${ORIG_BASE}..${ORIG_HEAD}"       "$_tmp_orig"
_stat_adds "${REBASED_BASE}..${REBASED_HEAD}" "$_tmp_rebased"

# ── Detect drops ──────────────────────────────────────────────────────────────
# For each file in original with >THRESHOLD adds, look it up in rebased.
# join -j2 would be ideal but sort keys differ; use awk for a single-pass lookup.
DROPS=0

# Build a lookup: "<file> <rebased_adds>" from _tmp_rebased (field order: adds file → flip)
_tmp_lookup="${_tmp_dir}/rebased_lookup.txt"
awk '{ print $2, $1 }' "$_tmp_rebased" | sort -k1 > "$_tmp_lookup"

while IFS=' ' read -r orig_add file; do
    [[ -z "${file:-}" ]] && continue
    [[ "${orig_add:-0}" -gt "$THRESHOLD" ]] || continue

    # Look up rebased add count for this file (0 if not found)
    rebased_add="$(awk -v f="$file" '$1==f { print $2; found=1; exit } END { if (!found) print 0 }' "$_tmp_lookup")"

    if [[ "${rebased_add:-0}" -eq 0 ]]; then
        warn "HUNK DROP: $file — ${orig_add} lines added in original, 0 in rebased"
        DROPS=$((DROPS + 1))
        if [[ "$DRY_RUN" -eq 0 ]]; then
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            payload="$(printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s","threshold":%d}' \
                "$ts" "$file" "$orig_add" "$ORIG_HEAD" "$REBASED_HEAD" "$THRESHOLD")"
            _ambient_write "$AMBIENT_LOG" "$payload"
        fi
    fi
done < "$_tmp_orig"

if [[ "$DROPS" -gt 0 ]]; then
    red ""
    red "post-rebase-verify: $DROPS file(s) silently dropped during rebase (INFRA-1526)."
    red "This indicates a merge driver discarded hunks instead of producing conflict markers."
    red "Inspect: git diff ${ORIG_HEAD}..${REBASED_HEAD} -- <file>"
    red "Recover: re-apply lost hunks and amend the rebased commit."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would exit 2 — drops=$DROPS"
        exit 0
    fi
    exit 2
fi

total_files=0
[[ -s "$_tmp_orig" ]] && total_files="$(wc -l < "$_tmp_orig" | tr -d ' ')"
info "✓ No hunk drops detected ($total_files original files checked, threshold=${THRESHOLD})"
exit 0
