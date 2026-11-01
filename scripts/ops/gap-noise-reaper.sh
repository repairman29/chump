#!/usr/bin/env bash
# scripts/ops/gap-noise-reaper.sh — RESILIENT-111
#
# Durable (launchd, no Claude session) drain of auto-filer-noise gaps:
#   1. title 'PR #N ... failing ...' where PR #N is MERGED/CLOSED (cache-first;
#      SKIP if OPEN or state unknown)
#   2. title 'EFFECTIVE: Wire%' whose description says it is already wired
#   3. title '%worktree cleanup%' (transient)
# Closes via `chump gap close --reason superseded` (RESILIENT-119) — never
# `gap ship` (INFRA-1392 proof-of-merge blocks no-PR gaps). Bounded per run;
# each close is appended to a jsonl log (reverse: chump gap set <ID> --status open).
#
# Usage: gap-noise-reaper.sh [--dry-run] [--limit N]
# Rust-First-Bypass: gh+sqlite3+chump glue, closes only via the chump gap close CLI
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
CACHE_DB="${CHUMP_NOISE_CACHE_DB:-$REPO_ROOT/.chump/github_cache.db}"
LOG="${CHUMP_NOISE_REAPER_LOG:-$HOME/.chump/gap-noise-reaper.jsonl}"
LOCK="${CHUMP_NOISE_REAPER_LOCK:-${TMPDIR:-/tmp}/chump-gap-noise-reaper.lock.d}"
DRY=0
LIMIT=50
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --limit)   LIMIT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "bad --limit" >&2; exit 2; }
[[ "$LIMIT" -gt 50 ]] && LIMIT=50
[[ -f "$DB" ]] || { echo "ERROR: state.db missing at $DB" >&2; exit 2; }
command -v chump >/dev/null 2>&1 || { echo "ERROR: chump binary required" >&2; exit 2; }

# single-instance (mkdir lock; flock is absent on macOS)
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "[gap-noise-reaper] another run holds $LOCK — exiting"; exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
mkdir -p "$(dirname "$LOG")"

# Prints OPEN|MERGED|CLOSED|UNKNOWN. Cache first, gh only on miss.
pr_state() {
    local n="$1" row st
    if [[ -f "$CACHE_DB" ]]; then
        row="$(sqlite3 "$CACHE_DB" "SELECT COALESCE(merged_at,''), COALESCE(json_extract(raw_payload_json,'\$.state'),'') FROM pr_state WHERE number=$n;" 2>/dev/null || true)"
        if [[ -n "$row" ]]; then
            [[ "${row%%|*}" != "" ]] && { echo MERGED; return; }
            st="$(printf '%s' "${row#*|}" | tr '[:lower:]' '[:upper:]')"
            case "$st" in OPEN|CLOSED|MERGED) echo "$st"; return ;; esac
        fi
    fi
    if command -v gh >/dev/null 2>&1; then
        st="$(CHUMP_GH_CALL_CRITICALITY=background gh pr view "$n" --json state -q .state 2>/dev/null || true)"
        case "$st" in OPEN|CLOSED|MERGED) echo "$st"; return ;; esac
    fi
    echo UNKNOWN
}

# One row per gap: newlines inside descriptions are flattened first.
CAND="$(sqlite3 -separator '|' "$DB" "SELECT id, title, REPLACE(COALESCE(description,''), char(10), ' ') FROM gaps WHERE status='open' AND (title LIKE 'PR #%failing%' OR title LIKE 'EFFECTIVE: Wire%' OR title LIKE '%worktree cleanup%') ORDER BY id;" 2>/dev/null)"

closed=0; skipped=0; errors=0
while IFS='|' read -r id title desc; do
    [[ -z "$id" || "$closed" -ge "$LIMIT" ]] && continue
    why=""
    if [[ "$title" =~ ^PR\ \#([0-9]+).*failing ]]; then
        n="${BASH_REMATCH[1]}"
        case "$(pr_state "$n")" in
            MERGED) why="pr-$n-merged" ;;
            CLOSED) why="pr-$n-closed" ;;
            *) skipped=$((skipped + 1)); continue ;;
        esac
    elif [[ "$title" == "EFFECTIVE: Wire"* ]]; then
        if printf '%s' "$desc" | grep -qiE 'already[- ]wired'; then why="already-wired"
        else skipped=$((skipped + 1)); continue; fi
    elif [[ "$title" == *"worktree cleanup"* ]]; then
        why="transient-worktree-cleanup"
    fi
    [[ -z "$why" ]] && continue
    if [[ "$DRY" -eq 1 ]]; then
        echo "  $id → would close ($why)"; closed=$((closed + 1)); continue
    fi
    if chump gap close "$id" --reason superseded >/dev/null 2>&1; then
        closed=$((closed + 1))
        printf '{"ts":"%s","event":"gap_noise_reaped","gap":"%s","why":"%s","prev_status":"open"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$why" >> "$LOG"
    else
        errors=$((errors + 1)); echo "  WARN $id: chump gap close failed" >&2
    fi
done <<< "$CAND"

echo "[gap-noise-reaper] closed=$closed skipped=$skipped errors=$errors$([[ $DRY -eq 1 ]] && echo ' (dry-run)')"
exit 0
