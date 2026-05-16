#!/usr/bin/env bash
# scripts/ops/disk-health-monitor.sh — INFRA-453
#
# Three-tier disk-space monitor. Runs every 5 min via launchd.
# Monitors: /, /System/Volumes/Data, /tmp, ~/Projects/Chump
#
# Tiers:
#   <10% free   → ALERT kind=disk_low
#   < 5% free   → ALERT kind=disk_critical
#   < 2% free   → ALERT kind=disk_critical (level=BLOCKING) +
#                 touch ~/.chump-fleet-pause-disk-critical
#
# Usage:
#   bash scripts/ops/disk-health-monitor.sh             # one-shot check
#   bash scripts/ops/disk-health-monitor.sh --dry-run   # never write to fs
#
# Env:
#   CHUMP_DISK_WARN_PCT       (default 10) free-pct below which to emit disk_low
#   CHUMP_DISK_CRITICAL_PCT   (default  5) free-pct below which to emit disk_critical
#   CHUMP_DISK_BLOCKING_PCT   (default  2) free-pct below which to pause fleet
#   CHUMP_DISK_MONITOR_DF_CMD   (default "df -Ph") df command override for testing
#   CHUMP_FLEET_PAUSE_FILE      (default ~/.chump-fleet-pause-disk-critical)
#   CHUMP_DISK_AUTO_REMEDIATE   (default 1) set 0 to disable auto-reaper invocation
#   CHUMP_DISK_REAPER_TIMEOUT_S (default 60) max seconds for auto-reaper run

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

WARN_PCT="${CHUMP_DISK_WARN_PCT:-10}"
CRITICAL_PCT="${CHUMP_DISK_CRITICAL_PCT:-5}"
BLOCKING_PCT="${CHUMP_DISK_BLOCKING_PCT:-2}"
DF_CMD="${CHUMP_DISK_MONITOR_DF_CMD:-df -Ph}"
PAUSE_FILE="${CHUMP_FLEET_PAUSE_FILE:-$HOME/.chump-fleet-pause-disk-critical}"
AUTO_REMEDIATE="${CHUMP_DISK_AUTO_REMEDIATE:-1}"
REAPER_TIMEOUT="${CHUMP_DISK_REAPER_TIMEOUT_S:-60}"
REAPER_SCRIPT="$SCRIPT_DIR/../coord/target-dir-reaper.sh"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[disk-health-monitor %s] %s\n' "$(ts)" "$*"; }

MONITOR_DIRS=("/" "/System/Volumes/Data" "/tmp" "$HOME/Projects/Chump")

# Deduplicate: skip a dir if we've already checked its filesystem device.
declare -A SEEN_DEVS

emit_ambient() {
    local kind="$1"; shift
    local body="$1"; shift
    local extra="${1:-}"
    [[ $DRY -eq 1 ]] && { log "DRY-RUN: would emit $kind — $body"; return 0; }
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    if [[ -n "$extra" ]]; then
        printf '{"ts":"%s","session":"disk-health-monitor","event":"ALERT","kind":"%s","body":"%s",%s}\n' \
            "$(ts)" "$kind" "$body" "$extra" >> "$AMBIENT" 2>/dev/null || true
    else
        printf '{"ts":"%s","session":"disk-health-monitor","event":"ALERT","kind":"%s","body":"%s"}\n' \
            "$(ts)" "$kind" "$body" >> "$AMBIENT" 2>/dev/null || true
    fi
}

# INFRA-1440: auto-invoke target-dir-reaper --critical when disk_critical fires.
# Capped to REAPER_TIMEOUT seconds so monitor never hangs. Emits
# disk_critical_auto_remediated with freed_gb on completion.
auto_remediate_disk() {
    if [[ "$AUTO_REMEDIATE" != "1" ]]; then
        log "auto-remediation disabled (CHUMP_DISK_AUTO_REMEDIATE=0)"
        return 0
    fi
    if [[ ! -x "$REAPER_SCRIPT" ]]; then
        log "WARN: target-dir-reaper.sh not found or not executable at $REAPER_SCRIPT — skipping auto-remediation"
        return 0
    fi
    if [[ "$DRY" -eq 1 ]]; then
        log "DRY-RUN: would invoke: timeout ${REAPER_TIMEOUT} bash $REAPER_SCRIPT --execute --critical"
        return 0
    fi
    log "auto-remediation: invoking target-dir-reaper --execute --critical (timeout ${REAPER_TIMEOUT}s)…"
    local reaper_out
    reaper_out="$(timeout "${REAPER_TIMEOUT}" bash "$REAPER_SCRIPT" --execute --critical 2>&1 || true)"
    log "$reaper_out"

    # Parse freed GB from summary line: "✓  summary: reaped N, skipped M, freed X.YGB"
    local freed_gb="0"
    freed_gb="$(printf '%s\n' "$reaper_out" | grep -oE 'freed [0-9]+\.[0-9]+GB' | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 0)"

    emit_ambient "disk_critical_auto_remediated" \
        "target-dir-reaper --critical completed; freed ${freed_gb}GB" \
        '"freed_gb":'"${freed_gb:-0}"',"timeout_s":'"$REAPER_TIMEOUT"
    log "auto-remediation complete: freed ${freed_gb}GB"
}

WORST_FREE=100
TRIGGERED=0

for dir in "${MONITOR_DIRS[@]}"; do
    # Use the closest existing ancestor when the exact path doesn't exist.
    check_dir="$dir"
    while [[ ! -d "$check_dir" && "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done
    [[ -d "$check_dir" ]] || continue

    # Dedup by device number to avoid double-counting APFS data volume.
    dev="$(stat -f%d "$check_dir" 2>/dev/null || stat -c%d "$check_dir" 2>/dev/null || echo "")"
    if [[ -n "$dev" && -n "${SEEN_DEVS[$dev]+set}" ]]; then
        log "SKIP $dir (same device as already-checked filesystem)"
        continue
    fi
    [[ -n "$dev" ]] && SEEN_DEVS[$dev]=1

    df_out="$($DF_CMD "$check_dir" 2>/dev/null | tail -1)" || {
        log "WARN: df failed for $check_dir"; continue
    }
    used_pct="$(printf '%s\n' "$df_out" | awk '{print $5}' | tr -d '%')"
    [[ "$used_pct" =~ ^[0-9]+$ ]] || { log "WARN: could not parse df output for $check_dir: $df_out"; continue; }
    free_pct=$(( 100 - used_pct ))
    [[ "$free_pct" -lt "$WORST_FREE" ]] && WORST_FREE="$free_pct"

    log "CHECK $dir → ${free_pct}% free (df: $df_out)"

    if [[ "$free_pct" -lt "$BLOCKING_PCT" ]]; then
        body="BLOCKING: ${free_pct}% free on ${dir} (blocking threshold ${BLOCKING_PCT}%). df: ${df_out}"
        log "BLOCKING: $body"
        emit_ambient "disk_critical" "$body" '"level":"BLOCKING","dir":"'"$dir"'","free_pct":'"$free_pct"
        if [[ $DRY -eq 0 ]]; then
            touch "$PAUSE_FILE" 2>/dev/null && log "fleet paused: $PAUSE_FILE"
            # INFRA-1437: close the alert→action loop. Auto-invoke the
            # target-dir-reaper in --critical mode so disk gets reclaimed
            # without operator intervention. Bounded by timeout so it can
            # never hang the monitor.
            auto_remediate_disk_critical
        else
            log "DRY-RUN: would touch $PAUSE_FILE + invoke target-dir-reaper --critical"
        fi
        # INFRA-1440: auto-invoke reaper in critical mode to reclaim disk immediately.
        auto_remediate_disk
        TRIGGERED=1
    elif [[ "$free_pct" -lt "$CRITICAL_PCT" ]]; then
        body="CRITICAL: ${free_pct}% free on ${dir} (critical threshold ${CRITICAL_PCT}%). df: ${df_out}"
        log "CRITICAL: $body"
        emit_ambient "disk_critical" "$body" '"level":"CRITICAL","dir":"'"$dir"'","free_pct":'"$free_pct"
        # INFRA-1440: auto-invoke reaper in critical mode to reclaim disk immediately.
        auto_remediate_disk
        TRIGGERED=1
    elif [[ "$free_pct" -lt "$WARN_PCT" ]]; then
        body="disk pressure: ${free_pct}% free on ${dir} (warn threshold ${WARN_PCT}%). df: ${df_out}"
        log "WARN: $body"
        emit_ambient "disk_low" "$body" '"level":"WARN","dir":"'"$dir"'","free_pct":'"$free_pct"
        TRIGGERED=1
    fi
done

if [[ "$TRIGGERED" -eq 0 ]]; then
    log "OK: all monitored filesystems ≥ ${WARN_PCT}% free (worst: ${WORST_FREE}%)"
fi

exit 0
