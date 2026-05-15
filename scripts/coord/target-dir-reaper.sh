#!/usr/bin/env bash
# target-dir-reaper.sh — INFRA-1349
#
# Pre-INFRA-1347 the only reaper deleted whole worktrees on staleness.
# But a worktree can be alive (open PR, recent commits, active lease) for
# days while its `target/` dir consumes 5-8 GB of reproducible cargo
# artifacts. With 250+ /private/tmp/chump-* worktrees, disk routinely hits
# 95+ % on operator machines.
#
# This reaper targets the build artifacts SEPARATELY from the worktrees:
#
#   - Skip worktrees with an active lease (heartbeat within TTL)
#   - Skip worktrees whose target/ was touched within IDLE_HOURS
#   - When free-disk < FREE_DISK_FLOOR_PCT %, prune target/ from every
#     stale + non-leased worktree.
#   - When disk is NOT under pressure, only prune target/ from worktrees
#     idle > IDLE_HARD_HOURS (longer threshold; opportunistic cleanup).
#
# Emits kind=target_artifact_reaped per reaped dir with bytes freed +
# worktree age, so the operator + audit chain can see what was reclaimed.
#
# Usage:
#   scripts/coord/target-dir-reaper.sh                 # dry-run by default
#   scripts/coord/target-dir-reaper.sh --execute       # actually delete
#   scripts/coord/target-dir-reaper.sh --force         # ignore disk threshold
#
# Env:
#   TARGET_REAPER_IDLE_HOURS       default 6   (delete under disk pressure)
#   TARGET_REAPER_IDLE_HARD_HOURS  default 48  (delete opportunistically)
#   TARGET_REAPER_FREE_DISK_FLOOR  default 20  (% — below = pressure)
#   TARGET_REAPER_WORKTREE_GLOB    default "/private/tmp/chump-* .claude/worktrees/*"
#   CHUMP_AMBIENT_LOG              override path to ambient.jsonl

set -uo pipefail

IDLE_HOURS="${TARGET_REAPER_IDLE_HOURS:-6}"
IDLE_HARD_HOURS="${TARGET_REAPER_IDLE_HARD_HOURS:-48}"
FREE_DISK_FLOOR="${TARGET_REAPER_FREE_DISK_FLOOR:-20}"
DRY_RUN=1
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute) DRY_RUN=0 ;;
        --force)   FORCE=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Load lease lib for active-lease check (INFRA-1212) ──────────────────────
# shellcheck source=../lib/lease.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/lease.sh"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

emit_event() {
    local path="$1" freed_gb="$2" worktree_age_h="$3" reason="$4"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","kind":"target_artifact_reaped","path":"%s","freed_gb":%s,"worktree_age_h":%s,"reason":"%s"}\n' \
        "$ts" "$path" "$freed_gb" "$worktree_age_h" "$reason" >> "$AMBIENT" 2>/dev/null || true
}

# Return free-disk percentage (integer). Uses df on the target's mount.
free_disk_pct() {
    local probe="${1:-/private/tmp}"
    df -P "$probe" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print 100 - $5 }'
}

# Return MB consumed by a path. Cheap du -ks (kibibytes / 1024 = MB).
path_size_mb() {
    local p="$1"
    du -ks "$p" 2>/dev/null | awk '{ printf "%d", $1 / 1024 }'
}

# Return the youngest file mtime under a path in hours-since-epoch.
# 0 means "right now"; higher = older.
path_idle_hours() {
    local p="$1"
    local newest
    # Most-recently-modified file under p
    newest=$(find "$p" -type f -print0 2>/dev/null \
        | xargs -0 stat -f %m 2>/dev/null \
        | sort -nr | head -1)
    [[ -z "$newest" ]] && { echo "9999"; return; }
    local now; now=$(date +%s)
    echo $(( (now - newest) / 3600 ))
}

# Active-lease check: returns 0 if any *.json in .chump-locks/ names this
# worktree dir AND its heartbeat is fresh (within CHUMP_LEASE_HEARTBEAT_TTL_S,
# default 600s). Delegates to lease.sh helpers.
worktree_has_live_lease() {
    local wt_dir="$1"
    local ttl="${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"
    while IFS= read -r lease; do
        [[ -f "$lease" ]] || continue
        local lease_wt
        lease_wt="$(lease_worktree "$lease")"
        # Substring match — handles both /private/tmp/<name> and bare-name.
        if [[ -n "$lease_wt" && "$wt_dir" == *"$lease_wt"* ]]; then
            if lease_is_fresh "$lease" "$ttl"; then
                return 0
            fi
        fi
    done < <(lease_iter --repo "$REPO_ROOT")
    return 1
}

# Glob expansion — protect against the default having NO matches.
declare -a CANDIDATE_DIRS
if [[ -n "${TARGET_REAPER_WORKTREE_GLOB:-}" ]]; then
    # shellcheck disable=SC2206
    CANDIDATE_DIRS=( ${TARGET_REAPER_WORKTREE_GLOB} )
else
    shopt -s nullglob
    CANDIDATE_DIRS=( /private/tmp/chump-* "$REPO_ROOT/.claude/worktrees"/* )
    shopt -u nullglob
fi

free_pct=$(free_disk_pct "/private/tmp")
[[ -z "$free_pct" ]] && free_pct=100
under_pressure=0
if (( free_pct < FREE_DISK_FLOOR )); then
    under_pressure=1
fi
if [[ $FORCE -eq 1 ]]; then
    under_pressure=1
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[target-dir-reaper] DRY RUN (pass --execute to delete)"
fi
echo "[target-dir-reaper] free-disk=${free_pct}%  pressure_floor=${FREE_DISK_FLOOR}%  pressure=$under_pressure"
echo "[target-dir-reaper] idle_hours_pressure=$IDLE_HOURS  idle_hours_opportunistic=$IDLE_HARD_HOURS"
echo "[target-dir-reaper] candidates=${#CANDIDATE_DIRS[@]} worktree(s)"
echo

reaped_count=0
total_freed_mb=0
skipped_lease=0
skipped_fresh=0
skipped_nopath=0
kept_count=0

printf "  %-50s %-10s %-10s %s\n" "PATH" "SIZE_MB" "IDLE_H" "ACTION"
printf "  %-50s %-10s %-10s %s\n" "----" "-------" "------" "------"

for wt_dir in "${CANDIDATE_DIRS[@]}"; do
    [[ -d "$wt_dir" ]] || { skipped_nopath=$((skipped_nopath+1)); continue; }
    target="$wt_dir/target"
    [[ -d "$target" ]] || continue

    size_mb=$(path_size_mb "$target")
    idle_h=$(path_idle_hours "$target")
    wt_short=$(basename "$wt_dir")

    # Lease check first — never touch active work.
    if worktree_has_live_lease "$wt_dir"; then
        skipped_lease=$((skipped_lease+1))
        printf "  %-50s %-10s %-10s %s\n" "$wt_short/target" "$size_mb" "$idle_h" "SKIP — active lease"
        continue
    fi

    # Decide threshold based on disk pressure.
    threshold="$IDLE_HARD_HOURS"
    reason="opportunistic_idle_${IDLE_HARD_HOURS}h"
    if [[ $under_pressure -eq 1 ]]; then
        threshold="$IDLE_HOURS"
        reason="disk_pressure_idle_${IDLE_HOURS}h"
    fi

    if (( idle_h < threshold )); then
        skipped_fresh=$((skipped_fresh+1))
        kept_count=$((kept_count+1))
        printf "  %-50s %-10s %-10s %s\n" "$wt_short/target" "$size_mb" "$idle_h" "KEEP — idle<${threshold}h"
        continue
    fi

    # Reap.
    if [[ $DRY_RUN -eq 1 ]]; then
        printf "  %-50s %-10s %-10s %s\n" "$wt_short/target" "$size_mb" "$idle_h" "WOULD REAP ($reason)"
        reaped_count=$((reaped_count+1))
        total_freed_mb=$((total_freed_mb + size_mb))
    else
        if rm -rf "$target" 2>/dev/null; then
            printf "  %-50s %-10s %-10s %s\n" "$wt_short/target" "$size_mb" "$idle_h" "REAPED ($reason)"
            reaped_count=$((reaped_count+1))
            total_freed_mb=$((total_freed_mb + size_mb))
            # Emit ambient event with freed-GB (1-decimal) + age + reason.
            freed_gb=$(awk -v mb="$size_mb" 'BEGIN { printf "%.2f", mb/1024 }')
            emit_event "$target" "$freed_gb" "$idle_h" "$reason"
        else
            printf "  %-50s %-10s %-10s %s\n" "$wt_short/target" "$size_mb" "$idle_h" "FAILED to delete"
        fi
    fi
done

echo
echo "── summary ──"
echo "  reaped:           $reaped_count target/ dir(s)"
printf "  freed:            %d MB (%.2f GB)\n" "$total_freed_mb" "$(awk -v mb="$total_freed_mb" 'BEGIN { print mb/1024 }')"
echo "  kept-fresh:       $skipped_fresh"
echo "  kept-leased:      $skipped_lease"
echo "  free-disk-now:    ${free_pct}%"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "  Re-run with --execute to actually delete."
fi
exit 0
