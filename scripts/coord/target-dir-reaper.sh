#!/usr/bin/env bash
# scripts/coord/target-dir-reaper.sh — INFRA-1349
#
# Reaps cargo target/ directories from idle worktrees when disk pressure
# is high. INFRA-1347 reaps whole worktrees but only after stale-checks
# pass; while a PR is in-flight, the target/ dir lives forever consuming
# 5-8GB each. With 254 worktrees today, math doesn't work — disk hit
# 97% on 2026-05-15.
#
# Build artifacts are fully reproducible by re-running cargo, so this
# is safe-by-default: never touches source, lease files, or git state.
#
# Usage:
#   target-dir-reaper.sh                      # dry-run, show what would happen
#   target-dir-reaper.sh --execute            # actually delete
#   target-dir-reaper.sh --execute --force    # ignore disk-pressure threshold
#
# Triggers:
#   - Disk free < CHUMP_TARGET_REAPER_DISK_MIN_GB (default 50)
#     OR --force
#   - Worktree's last mtime > CHUMP_TARGET_REAPER_IDLE_H (default 6) hours ago
#   - Worktree has NO active lease (.chump-locks/<gap>.json with expires_at > now)
#
# Output: per-target-dir status (skip-reason | reaped | bytes-freed)
# Ambient event: kind=target_artifact_reaped {path, freed_gb, worktree_age_h}

set -uo pipefail

DRY_RUN=1
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) DRY_RUN=0; shift ;;
    --force)   FORCE=1;   shift ;;
    --help|-h)
      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

DISK_MIN_GB="${CHUMP_TARGET_REAPER_DISK_MIN_GB:-50}"
IDLE_H="${CHUMP_TARGET_REAPER_IDLE_H:-6}"
# Where to look. /private/tmp/chump-* is the worktree home on macOS;
# .claude/worktrees/*/target on Linux/CI hosts. Both safe to scan.
SCAN_PATHS=("/private/tmp/chump-*")
# If the main repo has a .claude/worktrees dir, scan that too.
REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-$(pwd)}}"
if [[ -d "$REPO_ROOT/.claude/worktrees" ]]; then
  SCAN_PATHS+=("$REPO_ROOT/.claude/worktrees/*")
fi

ok()   { printf '\033[0;32m✓\033[0m  %s\n' "$*"; }
skip() { printf '\033[0;33m-\033[0m  %s\n' "$*"; }
do_()  { printf '\033[0;36m→\033[0m  %s\n' "$*"; }

# Check disk pressure.
free_gb=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -z "$free_gb" ]]; then
  free_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
fi
free_gb="${free_gb:-0}"

if [[ "$FORCE" -eq 0 && "$free_gb" -ge "$DISK_MIN_GB" ]]; then
  ok "disk has ${free_gb}GB free (threshold: ${DISK_MIN_GB}GB) — no action needed"
  exit 0
fi
do_ "disk free ${free_gb}GB < threshold ${DISK_MIN_GB}GB — scanning"

# Build set of gap-ids with active leases (so we skip their worktrees).
ACTIVE_LEASES=""
LOCK_DIR="$REPO_ROOT/.chump-locks"
if [[ -d "$LOCK_DIR" ]]; then
  now_secs=$(date +%s)
  for lease in "$LOCK_DIR"/*.json; do
    [[ -f "$lease" ]] || continue
    # Skip subdirectories (inbox, etc.)
    [[ "$lease" == */inbox/* ]] && continue
    # Parse expires_at — best-effort, ignore parse failures.
    exp=$(python3 -c "
import json, sys, datetime
try:
    with open('$lease') as f: d = json.load(f)
    e = d.get('expires_at','')
    if isinstance(e, str):
        t = datetime.datetime.fromisoformat(e.rstrip('Z').replace('+00:00','')).timestamp()
        print(int(t))
    elif isinstance(e, (int,float)):
        print(int(e))
except: pass
" 2>/dev/null)
    if [[ -n "$exp" && "$exp" -gt "$now_secs" ]]; then
      # Lease still live. Add gap-id (from filename or json) to skip set.
      gap=$(basename "$lease" .json | sed -E 's/^claim-([a-z]+)-([0-9]+).*/\1-\2/' | tr '[:lower:]' '[:upper:]')
      ACTIVE_LEASES+=" $gap"
    fi
  done
fi

total_freed_mb=0
reaped=0
skipped=0

for pattern in "${SCAN_PATHS[@]}"; do
  for wt in $pattern; do
    [[ -d "$wt" ]] || continue
    target="$wt/target"
    [[ -d "$target" ]] || continue
    # Worktree name → gap-id (best-effort uppercase).
    wt_name=$(basename "$wt")
    gap_id=$(echo "$wt_name" | sed -E 's/^chump-//' | tr '[:lower:]' '[:upper:]')
    # Skip if active lease.
    if [[ " $ACTIVE_LEASES " == *" $gap_id "* ]]; then
      skip "$target (active lease $gap_id)"
      skipped=$((skipped + 1))
      continue
    fi
    # Idle check — find any file inside modified within IDLE_H hours.
    idle_ok=1
    if find "$wt" -mmin -$((IDLE_H * 60)) -not -path "*/target/*" -print -quit 2>/dev/null | grep -q .; then
      idle_ok=0
    fi
    if [[ "$idle_ok" -eq 0 ]]; then
      skip "$target (active edits in last ${IDLE_H}h)"
      skipped=$((skipped + 1))
      continue
    fi
    # Reap.
    size_mb=$(du -sm "$target" 2>/dev/null | awk '{print $1}')
    size_mb=${size_mb:-0}
    if [[ "$DRY_RUN" -eq 1 ]]; then
      do_ "would reap $target (~${size_mb}MB)"
    else
      rm -rf "$target" 2>/dev/null && {
        ok "reaped $target (~${size_mb}MB)"
        reaped=$((reaped + 1))
        total_freed_mb=$((total_freed_mb + size_mb))
        # Emit ambient event.
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        wt_age_h=$(stat -f "%m" "$wt" 2>/dev/null | awk -v now="$(date +%s)" '{print int((now-$1)/3600)}')
        if [[ -d "$REPO_ROOT/.chump-locks" ]]; then
          printf '{"ts":"%s","kind":"target_artifact_reaped","path":"%s","freed_gb":%s,"worktree_age_h":%s}\n' \
            "$ts" "$target" "$(awk -v m="$size_mb" 'BEGIN{printf "%.2f", m/1024}')" \
            "${wt_age_h:-0}" >> "$REPO_ROOT/.chump-locks/ambient.jsonl"
        fi
      }
    fi
  done
done

freed_gb=$(awk -v m="$total_freed_mb" 'BEGIN{printf "%.1f", m/1024}')
echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  do_ "dry-run summary: would reap $reaped target/ dirs, skipped $skipped"
  do_ "re-run with --execute to actually delete"
else
  ok "summary: reaped $reaped, skipped $skipped, freed ${freed_gb}GB"
fi
