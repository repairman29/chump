#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector: compares file-level insertion counts before
# and after a rebase. Emits kind=rebase_hunk_dropped and exits non-zero if any
# file that had >THRESHOLD added lines in the original branch commits now has
# 0 added lines in the rebased commits.
#
# Background: the append-only merge driver (rust-main-append) silently dropped
# 173 lines of src/main.rs from PR #2216 (INFRA-1418) and caused the opposite
# pattern on PR #2173 (INFRA-1434). The driver has since been removed from
# .gitattributes, but this script acts as a safety net for any future
# merge-driver misconfiguration or git strategy regression.
#
# Usage:
#   post-rebase-verify.sh --base <ref> --orig-head <sha> [--repo <path>]
#                         [--threshold N] [--ambient <log>]
#
# Arguments:
#   --base <ref>        The ref we rebased onto (e.g. "origin/main")
#   --orig-head <sha>   The HEAD SHA before the rebase (git's ORIG_HEAD)
#   --repo <path>       Path to the git repo root. Default: auto-detect.
#   --threshold N       Min insertions in original commit to trigger check.
#                       Default: 50 (AC#6 spec).
#   --ambient <log>     Path to ambient.jsonl. Default: .chump-locks/ambient.jsonl
#
# Exit codes:
#   0   all good — no silent hunk drops detected
#   1   hunk drop(s) detected — emitted kind=rebase_hunk_dropped per drop
#   2   usage error / bad arguments
#
# Emits kind=rebase_hunk_dropped per dropped file (INFRA-1526 AC#8):
#   {ts, kind, file, lines_lost, original_commit, rebased_commit, base}

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
BASE=""
ORIG_HEAD=""
REPO=""
THRESHOLD=50
AMBIENT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)        BASE="$2"; shift 2 ;;
        --orig-head)   ORIG_HEAD="$2"; shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        --threshold)   THRESHOLD="$2"; shift 2 ;;
        --ambient)     AMBIENT="$2"; shift 2 ;;
        --*)           printf '[post-rebase-verify] unknown flag: %s\n' "$1" >&2; exit 2 ;;
        *)             printf '[post-rebase-verify] unexpected arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -z "$BASE" ]]; then
    printf '[post-rebase-verify] --base is required\n' >&2; exit 2
fi
if [[ -z "$ORIG_HEAD" ]]; then
    # Fall back to reading .git/ORIG_HEAD when the caller omits it
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _probe_repo="${REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")}"
    if [[ -f "${_probe_repo}/.git/ORIG_HEAD" ]]; then
        ORIG_HEAD="$(cat "${_probe_repo}/.git/ORIG_HEAD")"
    else
        printf '[post-rebase-verify] --orig-head is required (and .git/ORIG_HEAD not found)\n' >&2
        exit 2
    fi
fi

# ── Repo root ─────────────────────────────────────────────────────────────────
if [[ -z "$REPO" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ── Ambient log ───────────────────────────────────────────────────────────────
if [[ -z "$AMBIENT" ]]; then
    AMBIENT="${REPO}/.chump-locks/ambient.jsonl"
fi

_emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local json
    json="$(printf '{"ts":"%s","kind":"%s",%s}' "$ts" "$kind" "$extra")"
    printf '%s\n' "$json" >> "$AMBIENT" 2>/dev/null || true
    printf '%s\n' "$json" >&2
}

# ── Resolve refs to full SHAs ─────────────────────────────────────────────────
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
ORIG_SHA="$(git -C "$REPO" rev-parse "${ORIG_HEAD}^{commit}" 2>/dev/null || echo "$ORIG_HEAD")"

if [[ -z "$HEAD_SHA" ]] || [[ -z "$ORIG_SHA" ]]; then
    printf '[post-rebase-verify] could not resolve HEAD or ORIG_HEAD — skipping check\n' >&2
    exit 0
fi

# If no rebase actually happened (same SHA), nothing to verify.
if [[ "$HEAD_SHA" == "$ORIG_SHA" ]]; then
    printf '[post-rebase-verify] HEAD unchanged — no rebase occurred, skipping\n' >&2
    exit 0
fi

# ── Collect insertion counts before rebase ────────────────────────────────────
# For each file: how many lines were added in the original branch commits?
# We use `git diff --numstat BASE..ORIG_HEAD` which gives the net diff.
declare -A ORIG_INSERTIONS
while IFS=$'\t' read -r ins _del file; do
    [[ "$file" =~ ^[[:space:]]*$ ]] && continue
    [[ "$ins" == "-" ]] && continue  # binary file; skip
    ORIG_INSERTIONS["$file"]="${ins:-0}"
done < <(git -C "$REPO" diff --numstat "${BASE}..${ORIG_SHA}" -- . 2>/dev/null || true)

if [[ "${#ORIG_INSERTIONS[@]}" -eq 0 ]]; then
    printf '[post-rebase-verify] no files in original branch commits — nothing to check\n' >&2
    exit 0
fi

# ── Collect insertion counts after rebase ─────────────────────────────────────
declare -A NEW_INSERTIONS
while IFS=$'\t' read -r ins _del file; do
    [[ "$file" =~ ^[[:space:]]*$ ]] && continue
    [[ "$ins" == "-" ]] && continue
    NEW_INSERTIONS["$file"]="${ins:-0}"
done < <(git -C "$REPO" diff --numstat "${BASE}..${HEAD_SHA}" -- . 2>/dev/null || true)

# ── Compare ───────────────────────────────────────────────────────────────────
DROPS=0
for file in "${!ORIG_INSERTIONS[@]}"; do
    orig_ins="${ORIG_INSERTIONS[$file]}"
    if (( orig_ins <= THRESHOLD )); then
        continue
    fi
    new_ins="${NEW_INSERTIONS[$file]:-0}"
    if (( new_ins == 0 )); then
        printf '[post-rebase-verify] HUNK DROP: %s had %d insertions before rebase, 0 after\n' \
            "$file" "$orig_ins" >&2
        _emit "rebase_hunk_dropped" \
            "\"file\":\"${file}\",\"lines_lost\":${orig_ins},\"original_commit\":\"${ORIG_SHA}\",\"rebased_commit\":\"${HEAD_SHA}\",\"base\":\"${BASE}\""
        DROPS=$(( DROPS + 1 ))
    fi
done

if (( DROPS > 0 )); then
    printf '[post-rebase-verify] %d silent hunk drop(s) detected — push aborted\n' "$DROPS" >&2
    printf 'Inspect: git diff %s..%s vs git diff %s..%s\n' \
        "$BASE" "$ORIG_SHA" "$BASE" "$HEAD_SHA" >&2
    printf 'To recover: git reset --hard %s && resolve conflicts manually\n' "$ORIG_SHA" >&2
    exit 1
fi

printf '[post-rebase-verify] OK — no silent hunk drops detected (%d files checked, threshold=%d)\n' \
    "${#ORIG_INSERTIONS[@]}" "$THRESHOLD" >&2
exit 0
