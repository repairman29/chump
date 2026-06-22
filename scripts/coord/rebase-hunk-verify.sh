#!/usr/bin/env bash
# scripts/coord/rebase-hunk-verify.sh — Post-rebase hunk-drop verifier (INFRA-1526).
#
# Usage: rebase-hunk-verify.sh [--ambient PATH] [--threshold N] <original_sha> <rebased_sha> <new_base>
#
#   original_sha  — HEAD before rebase (after rebase git sets ORIG_HEAD to this)
#   rebased_sha   — HEAD after rebase
#   new_base      — ref or SHA we rebased onto (e.g. origin/main)
#
# Compares per-file added-line counts between the original feature commits and
# the rebased feature commits. If any file had >THRESHOLD added lines in the
# original but has 0 after rebase, that is a silent hunk drop (the pattern that
# lost 173 lines from INFRA-1418's src/main.rs and an EVENT_REGISTRY entry from
# INFRA-1434 on 2026-05-16).
#
# On drop detected:
#   - Emits kind=rebase_hunk_dropped to ambient.jsonl (best-effort)
#   - Prints a diagnostic to stderr
#   - Exits 1
#
# On any setup/resolution failure: exits 0 so callers are never blocked by a
# flaky verification tool.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMBIENT="${CHUMP_AMBIENT_FILE:-$SCRIPT_DIR/../../.chump-locks/ambient.jsonl}"
THRESHOLD=50
DROPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ambient)   AMBIENT="$2";    shift 2 ;;
        --threshold) THRESHOLD="$2";  shift 2 ;;
        -*)  echo "[hunk-verify] unknown flag: $1" >&2; exit 0 ;;
        *)   break ;;
    esac
done

ORIGINAL_SHA="${1:-}"
REBASED_SHA="${2:-}"
NEW_BASE="${3:-}"

if [[ -z "$ORIGINAL_SHA" || -z "$REBASED_SHA" || -z "$NEW_BASE" ]]; then
    echo "[hunk-verify] Usage: $0 [--ambient PATH] [--threshold N] <original_sha> <rebased_sha> <new_base>" >&2
    exit 0  # don't block caller on usage error
fi

# Resolve the new base ref to a SHA (handles refs like origin/main)
NEW_BASE_SHA=$(git rev-parse --verify "$NEW_BASE" 2>/dev/null) || {
    echo "[hunk-verify] Could not resolve new_base '$NEW_BASE' — skipping" >&2
    exit 0
}

# Old fork point: where the feature originally branched from main.
# git merge-base F D = B (where B is where the feature forked, D is new main tip).
OLD_BASE=$(git merge-base "$ORIGINAL_SHA" "$NEW_BASE_SHA" 2>/dev/null) || {
    echo "[hunk-verify] Could not find merge base between $ORIGINAL_SHA and $NEW_BASE_SHA — skipping" >&2
    exit 0
}

# Per-file added lines in the original feature commits (old fork point → original tip).
declare -A orig_adds
while IFS=$'\t' read -r add _del file; do
    [[ -z "$file" || "$add" == "-" ]] && continue
    orig_adds["$file"]=$(( ${orig_adds["$file"]:-0} + add ))
done < <(git diff --numstat "$OLD_BASE" "$ORIGINAL_SHA" 2>/dev/null || true)

if [[ ${#orig_adds[@]} -eq 0 ]]; then
    echo "[hunk-verify] No original changes found between $OLD_BASE..$ORIGINAL_SHA — skipping" >&2
    exit 0
fi

# Per-file added lines in the rebased feature commits (new main base → rebased tip).
declare -A rebased_adds
while IFS=$'\t' read -r add _del file; do
    [[ -z "$file" || "$add" == "-" ]] && continue
    rebased_adds["$file"]=$(( ${rebased_adds["$file"]:-0} + add ))
done < <(git diff --numstat "$NEW_BASE_SHA" "$REBASED_SHA" 2>/dev/null || true)

# Detect drops: file with >THRESHOLD original additions but 0 after rebase.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for file in "${!orig_adds[@]}"; do
    orig="${orig_adds[$file]}"
    rebased="${rebased_adds[$file]:-0}"
    if [[ "$orig" -gt "$THRESHOLD" && "$rebased" -eq 0 ]]; then
        echo "[hunk-verify] DROP: $file — $orig lines added in original ($ORIGINAL_SHA) but 0 after rebase ($REBASED_SHA)" >&2
        DROPS=$(( DROPS + 1 ))
        # Emit ambient event (best-effort; don't fail if ambient dir doesn't exist)
        if [[ -n "$AMBIENT" ]]; then
            printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s"}\n' \
                "$TS" "$file" "$orig" "$ORIGINAL_SHA" "$REBASED_SHA" \
                >> "$AMBIENT" 2>/dev/null || true
        fi
    fi
done

if [[ "$DROPS" -gt 0 ]]; then
    echo "[hunk-verify] FAIL: $DROPS file(s) with silent hunk drop — do not push until resolved" >&2
    exit 1
fi

echo "[hunk-verify] OK — no silent hunk drops (checked ${#orig_adds[@]} file(s), threshold=$THRESHOLD)"
exit 0
