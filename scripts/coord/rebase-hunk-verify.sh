#!/usr/bin/env bash
# scripts/coord/rebase-hunk-verify.sh — INFRA-1526
#
# Post-rebase verification: detect silently dropped hunks.
#
# After `git rebase`, ORIG_HEAD points to the pre-rebase branch tip.
# This script compares insertions per file between:
#   original:  merge-base(ORIG_HEAD, remote/base)..ORIG_HEAD
#   rebased:   remote/base..HEAD
#
# If any file had >THRESHOLD insertions originally but has 0 after rebase,
# the hunk was silently dropped. Emits kind=rebase_hunk_dropped to ambient.jsonl
# and exits non-zero so bot-merge.sh can abort before a bad push.
#
# Root cause caught by this check: append-only merge drivers (e.g. the now-removed
# rust-main-append driver, INFRA-1389 / INFRA-1526) that silently discarded hunks
# when falling back from pure-append detection to 3-way merge. The union driver
# on EVENT_REGISTRY.yaml / env-vars-internal.txt kept those registrations intact,
# producing register-without-emit / emit-without-register orphans.
#
# Usage:
#   bash scripts/coord/rebase-hunk-verify.sh [--remote <name>] [--base <ref>]
#                                             [--threshold N] [--no-fail]
#
# Options:
#   --remote <name>   Git remote (default: origin)
#   --base <ref>      Base branch (default: main)
#   --threshold N     Minimum insertion count to flag as suspicious (default: 50)
#   --no-fail         Emit event but do not exit non-zero (advisory mode)
#
# Environment:
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   GAP_ID              Gap ID for event context (optional)
#
# Exit codes:
#   0   no drops detected (or --no-fail)
#   1   one or more files had hunks silently dropped
#   2   not called after a rebase (ORIG_HEAD absent) — skips silently

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
GAP_ID="${GAP_ID:-}"

# ── Defaults ──────────────────────────────────────────────────────────────────
REMOTE="origin"
BASE_REF="main"
THRESHOLD=50
NO_FAIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)      REMOTE="$2";     shift 2 ;;
        --remote=*)    REMOTE="${1#*=}"; shift   ;;
        --base)        BASE_REF="$2";   shift 2 ;;
        --base=*)      BASE_REF="${1#*=}"; shift ;;
        --threshold)   THRESHOLD="$2"; shift 2 ;;
        --threshold=*) THRESHOLD="${1#*=}"; shift ;;
        --no-fail)     NO_FAIL=1; shift ;;
        *)             shift ;;
    esac
done

# ── Only meaningful immediately after a git rebase ────────────────────────────
ORIG_HEAD_FILE="$REPO_ROOT/.git/ORIG_HEAD"
if [[ ! -f "$ORIG_HEAD_FILE" ]]; then
    exit 0
fi
ORIG_HEAD="$(cat "$ORIG_HEAD_FILE")"
if [[ -z "$ORIG_HEAD" ]]; then
    exit 0
fi

FULL_BASE="${REMOTE}/${BASE_REF}"

# ── Old merge-base: where the feature branch diverged from main before rebase ─
OLD_BASE="$(git -C "$REPO_ROOT" merge-base "$ORIG_HEAD" "$FULL_BASE" 2>/dev/null || true)"
if [[ -z "$OLD_BASE" ]]; then
    printf '[rebase-hunk-verify] WARN: cannot compute merge-base(%s, %s) — skipping\n' \
        "ORIG_HEAD" "$FULL_BASE" >&2
    exit 0
fi

# ── Parse numstat for original feature: OLD_BASE..ORIG_HEAD ──────────────────
declare -A ORIG_INSERTIONS
while IFS=$'\t' read -r added _deleted file; do
    [[ "$added" == "-" ]] && continue   # binary file
    [[ -z "$file" ]] && continue
    ORIG_INSERTIONS["$file"]="${added:-0}"
done < <(git -C "$REPO_ROOT" diff --numstat "${OLD_BASE}..${ORIG_HEAD}" 2>/dev/null || true)

if [[ ${#ORIG_INSERTIONS[@]} -eq 0 ]]; then
    exit 0
fi

# ── Parse numstat for rebased feature: FULL_BASE..HEAD ───────────────────────
declare -A REBASED_INSERTIONS
while IFS=$'\t' read -r added _deleted file; do
    [[ "$added" == "-" ]] && continue
    [[ -z "$file" ]] && continue
    REBASED_INSERTIONS["$file"]="${added:-0}"
done < <(git -C "$REPO_ROOT" diff --numstat "${FULL_BASE}..HEAD" 2>/dev/null || true)

# ── Detect drops: >THRESHOLD insertions originally → 0 insertions after rebase ──
DROPS=()
for file in "${!ORIG_INSERTIONS[@]}"; do
    orig_lines="${ORIG_INSERTIONS[$file]}"
    rebased_lines="${REBASED_INSERTIONS[$file]:-0}"
    if (( orig_lines > THRESHOLD && rebased_lines == 0 )); then
        DROPS+=("${file}|${orig_lines}|${rebased_lines}")
    fi
done

if [[ ${#DROPS[@]} -eq 0 ]]; then
    printf '[rebase-hunk-verify] OK — no hunk drops detected (files=%d, threshold=%d)\n' \
        "${#ORIG_INSERTIONS[@]}" "$THRESHOLD" >&2
    exit 0
fi

# ── Drops found — emit ambient events and report ──────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
GAP_FIELD=""
[[ -n "$GAP_ID" ]] && GAP_FIELD=",\"gap_id\":\"${GAP_ID}\""

for drop in "${DROPS[@]}"; do
    IFS='|' read -r drop_file orig_lines rebased_lines <<< "$drop"
    printf '[rebase-hunk-verify] DROPPED: %s — original=%s insertions rebased=%s insertions\n' \
        "$drop_file" "$orig_lines" "$rebased_lines" >&2
    printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%s,"original_commit":"%s","rebased_commit":"%s","threshold":%d%s}\n' \
        "$TS" "$drop_file" "$orig_lines" "$ORIG_HEAD" "$HEAD_SHA" "$THRESHOLD" "$GAP_FIELD" \
        >> "$AMBIENT"
done

printf '[rebase-hunk-verify] FAIL — %d file(s) lost >%d lines after rebase; see ambient kind=rebase_hunk_dropped\n' \
    "${#DROPS[@]}" "$THRESHOLD" >&2

if [[ "$NO_FAIL" == "1" ]]; then
    exit 0
fi
exit 1
