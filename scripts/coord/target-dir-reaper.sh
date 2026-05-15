#!/usr/bin/env bash
# target-dir-reaper.sh — INFRA-1349
# Prune stale target/ directories in /tmp/chump-* and .claude/worktrees/*
# when disk pressure is high OR when worktrees idle > 6h.
#
# Rationale: each worktree's target/ is 5-8GB after build+test. With 254+
# worktrees accumulating, disk pressure reaches 97%. Build artifacts are
# reproducible; kill them when disk < 20% free OR worktree idle > 6h.
#
# Usage:
#   ./scripts/coord/target-dir-reaper.sh                    # dry-run
#   ./scripts/coord/target-dir-reaper.sh --execute           # actually delete
#   ./scripts/coord/target-dir-reaper.sh --execute --disk-pct 20
#   CHUMP_REAPER_IDLE_HOURS=8 ./scripts/coord/target-dir-reaper.sh --execute
#
# Environment variables:
#   CHUMP_REAPER_IDLE_HOURS     hours idle before reap (default 6)
#   CHUMP_REAPER_DISK_PCT       disk threshold % to trigger (default 20)
#   CHUMP_REAPER_SAFETY_CHECK   0 to skip active-lease checks (testing only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EXECUTE=0
IDLE_HOURS="${CHUMP_REAPER_IDLE_HOURS:-6}"
DISK_THRESHOLD_PCT="${CHUMP_REAPER_DISK_PCT:-20}"
SAFETY_CHECK="${CHUMP_REAPER_SAFETY_CHECK:-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)      EXECUTE=1 ;;
        --dry-run)      EXECUTE=0 ;;
        --disk-pct)     DISK_THRESHOLD_PCT="$2"; shift ;;
        --idle-hours)   IDLE_HOURS="$2"; shift ;;
        -h|--help)
            sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
IDLE_SECONDS=$((IDLE_HOURS * 3600))
NOW=$(date +%s)

_dry_label="[DRY-RUN]"
[[ $EXECUTE -eq 1 ]] && _dry_label=""

_total_bytes=0
_total_freed=0
_reaped_count=0

# ── Helper: calculate free disk percentage ────────────────────────────────────
get_free_disk_pct() {
    local mount_point="${1:-.}"
    # df returns: Filesystem, Size, Used, Avail, %Used, Mounted on
    df "$mount_point" 2>/dev/null | awk 'NR==2 {print 100 - $5}' || echo "50"
}

# ── Helper: check if worktree has active lease ────────────────────────────────
has_active_lease() {
    local wt_path="$1"
    [[ "$SAFETY_CHECK" != "1" ]] && return 1

    # Check if any lease in .chump-locks/*.json has this worktree
    # and has a fresh heartbeat (within TTL)
    if [[ ! -d "${REPO_ROOT}/.chump-locks" ]]; then
        return 1
    fi

    local lease_ttl=600  # default 10 min
    local now
    now=$(date +%s)

    for lease_file in "${REPO_ROOT}/.chump-locks"/*.json; do
        [[ -f "$lease_file" ]] || continue

        # Check if this lease mentions our worktree
        if jq -e ".worktree_path == \"$wt_path\"" "$lease_file" >/dev/null 2>&1; then
            # Check heartbeat freshness
            local hb
            hb=$(jq -r '.heartbeat_ts // 0' "$lease_file" 2>/dev/null || echo 0)
            [[ "$hb" == "null" ]] && hb=0
            local age=$((now - hb))
            if [[ $age -lt $lease_ttl ]]; then
                return 0  # active
            fi
        fi
    done
    return 1  # inactive
}

# ── Helper: prune a target/ directory ─────────────────────────────────────────
maybe_delete_target() {
    local target_path="$1"
    local worktree_path="${2:-.}"

    [[ -d "$target_path" ]] || return 0

    local size_bytes
    size_bytes=$(du -sk "$target_path" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    local size_gb=$(( size_bytes / 1024 / 1024 / 1024 ))
    local size_mb=$(( size_bytes / 1024 / 1024 ))

    local mtime
    mtime=$(stat -f %m "$target_path" 2>/dev/null || stat -c %Y "$target_path" 2>/dev/null || echo 0)
    local age_secs=$((NOW - mtime))
    local age_hours=$((age_secs / 3600))

    echo "${_dry_label}  prune: ${target_path} (${age_hours}h idle, ~${size_gb}GB)"

    if [[ $EXECUTE -eq 1 ]]; then
        if ! rm -rf "$target_path" 2>/dev/null; then
            echo "    ERROR: rm -rf failed for ${target_path}" >&2
            printf '{"ts":"%s","kind":"target_artifact_reaped","path":"%s","worktree":"%s","error":"rm_failed","status":"failed"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target_path" "$worktree_path" \
                >> "$AMBIENT_LOG" 2>/dev/null || true
            return 1
        fi
    fi

    _total_bytes=$(( _total_bytes + size_bytes ))
    _total_freed=$(( _total_freed + size_gb ))
    _reaped_count=$(( _reaped_count + 1 ))

    # Emit per-artifact ambient event
    printf '{"ts":"%s","kind":"target_artifact_reaped","path":"%s","worktree":"%s","freed_gb":%d,"freed_mb":%d,"age_hours":%d,"dry_run":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target_path" "$worktree_path" \
        "$size_gb" "$size_mb" "$age_hours" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── Check disk pressure ──────────────────────────────────────────────────────
free_pct=$(get_free_disk_pct "$REPO_ROOT")
echo "[target-dir-reaper] Disk: ${free_pct}% free (threshold: ${DISK_THRESHOLD_PCT}%)"
echo "[target-dir-reaper] Idle threshold: ${IDLE_HOURS}h (${IDLE_SECONDS}s)"

# Determine if we should reap: either disk is low OR explicit execute
SHOULD_REAP=$EXECUTE
if [[ $free_pct -lt $DISK_THRESHOLD_PCT ]]; then
    echo "[target-dir-reaper] Disk pressure high (${free_pct}% < ${DISK_THRESHOLD_PCT}%) — reaping enabled"
    SHOULD_REAP=1
fi

if [[ $SHOULD_REAP -eq 0 ]]; then
    echo "[target-dir-reaper] Disk pressure normal — skipping (use --execute to force)"
    exit 0
fi

# ── Scan .claude/worktrees/* ──────────────────────────────────────────────────
WORKTREES_DIR="${REPO_ROOT}/.claude/worktrees"
if [[ -d "$WORKTREES_DIR" ]]; then
    echo "[target-dir-reaper] Scanning ${WORKTREES_DIR}/*"
    while IFS= read -r -d '' wt_dir; do
        [[ -d "$wt_dir" ]] || continue
        target_dir="${wt_dir}/target"
        [[ -d "$target_dir" ]] || continue

        # Skip if worktree has active lease
        if has_active_lease "$wt_dir"; then
            echo "  skip (active lease): ${wt_dir}"
            continue
        fi

        # Check age
        mtime=$(stat -f %m "$target_dir" 2>/dev/null || stat -c %Y "$target_dir" 2>/dev/null || echo 0)
        age=$((NOW - mtime))
        if [[ $age -ge $IDLE_SECONDS ]]; then
            maybe_delete_target "$target_dir" "$wt_dir"
        else
            age_hours=$((age / 3600))
            echo "  skip (fresh, ${age_hours}h old): ${wt_dir}"
        fi
    done < <(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# ── Scan /tmp/chump-* and /private/tmp/chump-* ───────────────────────────────
echo "[target-dir-reaper] Scanning /tmp/chump-* and /private/tmp/chump-*"
for tmp_root in /tmp /private/tmp; do
    [[ -d "$tmp_root" ]] || continue
    for wt_dir in "${tmp_root}"/chump-*; do
        [[ -d "$wt_dir" ]] || continue
        target_dir="${wt_dir}/target"
        [[ -d "$target_dir" ]] || continue

        # Skip if worktree has active lease
        if has_active_lease "$wt_dir"; then
            echo "  skip (active lease): ${wt_dir}"
            continue
        fi

        # Check age
        mtime=$(stat -f %m "$target_dir" 2>/dev/null || stat -c %Y "$target_dir" 2>/dev/null || echo 0)
        age=$((NOW - mtime))
        if [[ $age -ge $IDLE_SECONDS ]]; then
            maybe_delete_target "$target_dir" "$wt_dir"
        else
            age_hours=$((age / 3600))
            echo "  skip (fresh, ${age_hours}h old): ${wt_dir}"
        fi
    done
done

# ── Summary ──────────────────────────────────────────────────────────────────
_total_mb=$(( _total_bytes / 1024 / 1024 ))
echo ""
echo "[target-dir-reaper] ${_dry_label} Done: ${_reaped_count} targets, ~${_total_freed}GB (${_total_mb}MB)"
if [[ $EXECUTE -eq 0 && $_reaped_count -gt 0 ]]; then
    echo "[target-dir-reaper] Re-run with --execute to actually delete."
fi

# Summary ambient event
printf '{"ts":"%s","kind":"target_dir_reaper_summary","reaped_count":%d,"freed_gb":%d,"freed_bytes":%d,"idle_hours":%d,"disk_free_pct":%d,"execute":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_reaped_count" "$_total_freed" "$_total_bytes" \
    "$IDLE_HOURS" "$free_pct" \
    "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
