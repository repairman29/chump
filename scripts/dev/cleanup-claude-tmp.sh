#!/usr/bin/env bash
# cleanup-claude-tmp.sh — INFRA-400
# Prunes stale /private/tmp/claude-*/ task-output directories older than 24h.
# Preserves currently-active session paths (detected via lsof or process list).
# Reports to ambient.jsonl as kind=tmp_cleanup.
set -euo pipefail

[[ "${CHUMP_TMP_CLEANUP_DISABLE:-0}" == "1" ]] && exit 0

MAX_AGE_HOURS="${CHUMP_TMP_CLEANUP_MAX_AGE_H:-24}"
# Convert to seconds for find -mtime equivalence
MAX_AGE_S=$(( MAX_AGE_HOURS * 3600 ))

REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null || echo "")}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:+$REPO_ROOT/.chump-locks/ambient.jsonl}}"

bytes_freed=0
files_removed=0
dirs_pruned=0

# Detect active session directories: any /private/tmp/claude-* path currently
# open by a running process (rough heuristic via lsof).
active_paths=""
if command -v lsof >/dev/null 2>&1; then
    active_paths=$(lsof -Fn 2>/dev/null | grep '^n/private/tmp/claude' | sed 's|^n||' | sort -u || true)
fi

now=$(date +%s)

for dir in /private/tmp/claude-*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"

    # Skip if any process has this directory open
    if echo "$active_paths" | grep -qF "$dir" 2>/dev/null; then
        continue
    fi

    # Check mtime of the directory itself
    mtime=$(stat -f '%m' "$dir" 2>/dev/null || stat --format='%Y' "$dir" 2>/dev/null || echo 0)
    age_s=$(( now - mtime ))
    if [[ $age_s -lt $MAX_AGE_S ]]; then
        continue
    fi

    # Stale — measure then remove
    dir_bytes=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    dir_files=$(find "$dir" -type f 2>/dev/null | wc -l || echo 0)
    bytes_freed=$(( bytes_freed + dir_bytes ))
    files_removed=$(( files_removed + dir_files ))
    dirs_pruned=$(( dirs_pruned + 1 ))
    rm -rf "$dir"
    echo "[cleanup-claude-tmp] removed $dir (age ${age_s}s, ${dir_files} files, ${dir_bytes} bytes)"
done

echo "[cleanup-claude-tmp] done: removed $dirs_pruned dirs, $files_removed files, $bytes_freed bytes freed"

# Emit to ambient.jsonl
if [[ -n "${AMBIENT_LOG:-}" ]] && [[ -d "$(dirname "$AMBIENT_LOG")" ]]; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    session="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-cleanup-cron}}"
    printf '{"ts":"%s","session":"%s","kind":"tmp_cleanup","dirs_pruned":%d,"files_removed":%d,"bytes_freed":%d}\n' \
        "$ts" "$session" "$dirs_pruned" "$files_removed" "$bytes_freed" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
fi
