#!/usr/bin/env bash
# scripts/ops/ambient-rotate-now.sh — INFRA-1468
#
# Force-rotate ambient.jsonl immediately regardless of file size.
# Use this for emergency cleanup (file too large, reads hanging) or on
# fleet restart to start each session with a fresh log.
#
# Usage:
#   bash scripts/ops/ambient-rotate-now.sh
#   bash scripts/ops/ambient-rotate-now.sh --dry-run   # print what would happen
#
# Env:
#   CHUMP_REPO        override repo root (default: git rev-parse --show-toplevel)
#   CHUMP_AMBIENT_LOG override ambient.jsonl path (default: <repo>/.chump-locks/ambient.jsonl)
#
# Rotation sequence (same as INFRA-941 in-process rotation):
#   ambient.jsonl.2  →  deleted
#   ambient.jsonl.1  →  ambient.jsonl.2
#   ambient.jsonl    →  ambient.jsonl.1   (atomic rename)
#
# After rotation a fresh ambient.jsonl is created with a summary event.

set -uo pipefail

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# ── Resolve paths ──────────────────────────────────────────────────────────────
if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
    AMBIENT="$CHUMP_AMBIENT_LOG"
elif [[ -n "${CHUMP_REPO:-}" ]]; then
    AMBIENT="$CHUMP_REPO/.chump-locks/ambient.jsonl"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
    # Resolve to main repo root (linked worktrees have a .git file, not dir)
    GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$GIT_COMMON" != ".git" && -n "$GIT_COMMON" ]]; then
        REPO_ROOT="$(dirname "$GIT_COMMON")"
    fi
    AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
fi

# ── Bail if nothing to rotate ──────────────────────────────────────────────────
if [[ ! -f "$AMBIENT" ]]; then
    echo "[ambient-rotate-now] no ambient.jsonl at $AMBIENT — nothing to do"
    exit 0
fi

SIZE_BYTES="$(wc -c < "$AMBIENT" 2>/dev/null || echo 0)"
SIZE_MB="$(awk "BEGIN{printf \"%.1f\", $SIZE_BYTES/1048576}")"
LINE_COUNT="$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)"

if $DRY_RUN; then
    echo "[ambient-rotate-now] DRY-RUN: would rotate $AMBIENT ($SIZE_MB MB / $LINE_COUNT lines)"
    echo "[ambient-rotate-now] DRY-RUN:   $AMBIENT → ${AMBIENT}.1"
    echo "[ambient-rotate-now] DRY-RUN:   ${AMBIENT}.1 → ${AMBIENT}.2 (if exists)"
    echo "[ambient-rotate-now] DRY-RUN:   ${AMBIENT}.2 → deleted (if exists)"
    exit 0
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Rotation sequence ──────────────────────────────────────────────────────────
echo "[ambient-rotate-now] rotating $AMBIENT ($SIZE_MB MB / $LINE_COUNT lines)"

# Remove oldest slot
[[ -f "${AMBIENT}.2" ]] && rm -f "${AMBIENT}.2"

# Shift .1 → .2
[[ -f "${AMBIENT}.1" ]] && mv "${AMBIENT}.1" "${AMBIENT}.2"

# Atomic rename current → .1
mv "$AMBIENT" "${AMBIENT}.1"

# ── Write summary event to fresh file ─────────────────────────────────────────
printf '{"ts":"%s","kind":"ambient_rotated","size_bytes_before":%d,"lines_before":%d,"archive":"%s.1"}\n' \
    "$TS" "$SIZE_BYTES" "$LINE_COUNT" "$AMBIENT" \
    >> "$AMBIENT"

echo "[ambient-rotate-now] done: ${AMBIENT}.1 (${SIZE_MB} MB archived)"
echo "[ambient-rotate-now] fresh $AMBIENT started"
