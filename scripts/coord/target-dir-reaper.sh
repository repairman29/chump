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
#   target-dir-reaper.sh --execute --critical # critical mode: skip idle check
#
# Triggers:
#   - Disk free < CHUMP_TARGET_REAPER_DISK_MIN_GB (default 50)
#     OR --force
#   - Worktree's last mtime > CHUMP_TARGET_REAPER_IDLE_H (default 6) hours ago
#     UNLESS critical mode is active (see below)
#   - Worktree has NO active lease (.chump-locks/<gap>.json with expires_at > now)
#
# Critical mode (INFRA-1431):
#   Activated by --critical flag OR when free disk < CHUMP_REAPER_CRITICAL_GB (default 10).
#   In critical mode the idle-mtime check is SKIPPED — active lease is the only guard.
#   Disable auto-escalation: CHUMP_REAPER_NEVER_ESCALATE=1
#   Emits kind=target_artifact_critical_reap instead of target_artifact_reaped.
#
# Output: per-target-dir status (skip-reason | reaped | bytes-freed)
# Ambient event: kind=target_artifact_reaped {path, freed_gb, worktree_age_h}

set -uo pipefail

DRY_RUN=1
FORCE=0
CRITICAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute)  DRY_RUN=0;  shift ;;
    --force)    FORCE=1;    shift ;;
    --critical) CRITICAL=1; shift ;;
    --help|-h)
      sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

DISK_MIN_GB="${CHUMP_TARGET_REAPER_DISK_MIN_GB:-50}"
IDLE_H="${CHUMP_TARGET_REAPER_IDLE_H:-6}"
# INFRA-1431: auto-escalate to critical mode when disk free drops below this.
CRITICAL_GB="${CHUMP_REAPER_CRITICAL_GB:-10}"
NEVER_ESCALATE="${CHUMP_REAPER_NEVER_ESCALATE:-0}"
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

# INFRA-1431: auto-escalate to critical mode when disk pressure is severe.
if [[ "$CRITICAL" -eq 0 && "$NEVER_ESCALATE" -ne 1 && "$free_gb" -lt "$CRITICAL_GB" ]]; then
  CRITICAL=1
  do_ "WARNING: disk critically low (${free_gb}GB < ${CRITICAL_GB}GB) — critical mode: bypassing ${IDLE_H}h idle threshold; active leases still protected"
fi

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
    # Idle check — skipped in critical mode; active lease is the only guard then.
    if [[ "$CRITICAL" -eq 0 ]]; then
      idle_ok=1
      if find "$wt" -mmin -$((IDLE_H * 60)) -not -path "*/target/*" -print -quit 2>/dev/null | grep -q .; then
        idle_ok=0
      fi
      if [[ "$idle_ok" -eq 0 ]]; then
        skip "$target (active edits in last ${IDLE_H}h)"
        skipped=$((skipped + 1))
        continue
      fi
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
        # Emit ambient event. Use distinct kind in critical mode (INFRA-1431).
        _event_kind="target_artifact_reaped"
        [[ "$CRITICAL" -eq 1 ]] && _event_kind="target_artifact_critical_reap"
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        wt_age_h=$(stat -f "%m" "$wt" 2>/dev/null | awk -v now="$(date +%s)" '{print int((now-$1)/3600)}')
        if [[ -d "$REPO_ROOT/.chump-locks" ]]; then
          printf '{"ts":"%s","kind":"%s","path":"%s","freed_gb":%s,"worktree_age_h":%s}\n' \
            "$ts" "$_event_kind" "$target" "$(awk -v m="$size_mb" 'BEGIN{printf "%.2f", m/1024}')" \
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
