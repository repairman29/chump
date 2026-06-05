#!/usr/bin/env bash
# onboard-scout-scheduler.sh (MISSION-038, Phase-B Tier-1 of MISSION-032)
# — Periodic scheduler that picks stale repos from the `repos` table and
#   invokes `chump onboard <owner/repo>` on each, rate-limited.
#
# Why: With 100-10,000 tracked repos, manual `chump onboard <repo>` doesn't
# scale. This daemon reads the repos table, picks up to N repos where
# last_scan_at < CHUMP_ONBOARD_SCHED_STALE_DAYS ago (or never), rate-limits
# the batch, and updates last_scan_at after each successful scan.
#
# Safety:
#   - Per-repo active-lease check — skips repos where another agent holds a
#     claim on external_repo:<owner>/<repo> to avoid concurrent onboard.
#   - Idempotent: re-run within 5 min of a batch yields 0 scheduled (all
#     last_scan_at values were just updated).
#   - Rate-limited: CHUMP_ONBOARD_SCHED_RATE_PER_HR caps repos per invocation.
#
# Usage:
#   ./scripts/ops/onboard-scout-scheduler.sh
#   ./scripts/ops/onboard-scout-scheduler.sh --dry-run       # skip actual invocations
#   ./scripts/ops/onboard-scout-scheduler.sh --rate-per-hr 2
#   ./scripts/ops/onboard-scout-scheduler.sh --stale-days 3
#
# Install hourly via launchd:
#   cp scripts/setup/com.chump.onboard-scout-scheduler.plist ~/Library/LaunchAgents/
#   launchctl load -w ~/Library/LaunchAgents/com.chump.onboard-scout-scheduler.plist
#
# Tunable env:
#   CHUMP_ONBOARD_SCHED_RATE_PER_HR   (default 5)
#   CHUMP_ONBOARD_SCHED_STALE_DAYS    (default 7)
#   CHUMP_ONBOARD_ROOT                (default ~/.chump/external)
#   CHUMP_ONBOARD_SCHED_DRY_RUN       (default 0; set 1 to skip actual onboard)
#   CHUMP_STATE_DB                    (default ~/.chump/state.db or auto-detect)

set -euo pipefail

RATE_PER_HR="${CHUMP_ONBOARD_SCHED_RATE_PER_HR:-5}"
STALE_DAYS="${CHUMP_ONBOARD_SCHED_STALE_DAYS:-7}"
ONBOARD_ROOT="${CHUMP_ONBOARD_ROOT:-$HOME/.chump/external}"
DRY_RUN="${CHUMP_ONBOARD_SCHED_DRY_RUN:-0}"

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)          DRY_RUN=1; shift ;;
        --rate-per-hr)      RATE_PER_HR="$2"; shift 2 ;;
        --rate-per-hr=*)    RATE_PER_HR="${1#--rate-per-hr=}"; shift ;;
        --stale-days)       STALE_DAYS="$2"; shift 2 ;;
        --stale-days=*)     STALE_DAYS="${1#--stale-days=}"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0 ;;
        *) echo "[onboard-scout-scheduler] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Validate numeric params
[[ "$RATE_PER_HR" =~ ^[1-9][0-9]*$ ]] || { echo "[onboard-scout-scheduler] --rate-per-hr must be a positive integer (got: $RATE_PER_HR)" >&2; exit 2; }
[[ "$STALE_DAYS" =~ ^[1-9][0-9]*$ ]]  || { echo "[onboard-scout-scheduler] --stale-days must be a positive integer (got: $STALE_DAYS)" >&2; exit 2; }

# Locate state.db — prefer CHUMP_STATE_DB, then walk up from script location
if [[ -n "${CHUMP_STATE_DB:-}" ]]; then
    STATE_DB="$CHUMP_STATE_DB"
else
    # Try well-known paths
    CANDIDATE1="$HOME/.chump/state.db"
    CANDIDATE2="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.chump/state.db"
    if [[ -f "$CANDIDATE2" ]]; then
        STATE_DB="$CANDIDATE2"
    elif [[ -f "$CANDIDATE1" ]]; then
        STATE_DB="$CANDIDATE1"
    else
        echo "[onboard-scout-scheduler] ERROR: cannot locate state.db — set CHUMP_STATE_DB" >&2
        exit 1
    fi
fi

AMBIENT="${CHUMP_AMBIENT_PATH:-$HOME/Projects/Chump/.chump-locks/ambient.jsonl}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '[onboard-scout-scheduler] %s %s\n' "$(_ts)" "$*"; }

# Emit an ambient event (best-effort; no failure if path absent).
# scanner-anchor: "kind":"onboard_scan_scheduled"
# scanner-anchor: "kind":"onboard_scan_batch_complete"
_emit() {
    local kind="$1" payload="$2"
    if [[ -f "$AMBIENT" ]] || [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' \
            "$(_ts)" "$kind" "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi
}

# Check if a repo has an active lease in state.db.
# Returns 0 (true) if an active lease exists, 1 (false) otherwise.
_has_active_lease() {
    local owner="$1" repo="$2"
    local now
    now="$(date +%s)"
    local count
    count="$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM leases l
         JOIN gaps g ON l.gap_id = g.id
         WHERE g.skills_required LIKE '%external_repo:${owner}/${repo}%'
           AND l.expires_at > ${now};" 2>/dev/null || echo "0")"
    [[ "$count" -gt 0 ]]
}

_log "starting (rate_per_hr=$RATE_PER_HR, stale_days=$STALE_DAYS, dry_run=$DRY_RUN, db=$STATE_DB)"

# Compute the stale cutoff epoch
STALE_CUTOFF=$(( $(date +%s) - STALE_DAYS * 86400 ))

# Query stale repos: status='active' AND (last_scan_at IS NULL OR last_scan_at < cutoff)
# Order by last_scan_at ASC (oldest first), limit to RATE_PER_HR
# Avoid mapfile (bash 4+, macOS ships 3.2) — use a portable while-read pattern.
STALE_REPOS=()
while IFS= read -r row; do
    [[ -n "$row" ]] && STALE_REPOS+=("$row")
done < <(
    sqlite3 "$STATE_DB" \
        "SELECT id FROM repos
         WHERE status='active'
           AND (last_scan_at IS NULL OR last_scan_at < ${STALE_CUTOFF})
         ORDER BY last_scan_at ASC NULLS FIRST
         LIMIT ${RATE_PER_HR};" 2>/dev/null || true
)

total_stale="${#STALE_REPOS[@]}"
_log "found $total_stale stale repo(s) (limit=$RATE_PER_HR)"

if [[ "$total_stale" -eq 0 ]]; then
    _log "nothing to schedule — all repos are fresh or no repos tracked"
    _emit "onboard_scan_batch_complete" \
        "\"scheduled\":0,\"skipped_lease\":0,\"errors\":0,\"dry_run\":${DRY_RUN},\"rate_per_hr\":${RATE_PER_HR},\"stale_days\":${STALE_DAYS}"
    exit 0
fi

scheduled=0
skipped_lease=0
errors=0

for repo_id in "${STALE_REPOS[@]}"; do
    # repo_id is "owner/repo" (the repos.id primary key)
    owner="${repo_id%%/*}"
    repo_name="${repo_id#*/}"

    # Per-repo active-lease check
    if _has_active_lease "$owner" "$repo_name"; then
        _log "skip $repo_id — active lease detected"
        skipped_lease=$((skipped_lease + 1))
        continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log "DRY: would onboard $repo_id"
        # In dry-run, emit per-repo event but skip state mutation
        _emit "onboard_scan_scheduled" \
            "\"repo\":\"${repo_id}\",\"dry_run\":1"
        scheduled=$((scheduled + 1))
        continue
    fi

    _log "scheduling onboard for $repo_id"

    # Invoke chump onboard; capture exit code without aborting on failure
    if chump onboard "$repo_id" >/dev/null 2>&1; then
        # Update last_scan_at in repos table
        now_epoch="$(date +%s)"
        chump repos set "$repo_id" --last-scan-at "$now_epoch" 2>/dev/null || \
            _log "WARN: failed to update last_scan_at for $repo_id"

        _emit "onboard_scan_scheduled" \
            "\"repo\":\"${repo_id}\",\"dry_run\":0"
        scheduled=$((scheduled + 1))
        _log "scheduled $repo_id (last_scan_at updated)"
    else
        _log "WARN: chump onboard $repo_id failed — skipping last_scan_at update"
        errors=$((errors + 1))
    fi
done

_log "done — scheduled=$scheduled skipped_lease=$skipped_lease errors=$errors dry_run=$DRY_RUN"

_emit "onboard_scan_batch_complete" \
    "\"scheduled\":${scheduled},\"skipped_lease\":${skipped_lease},\"errors\":${errors},\"dry_run\":${DRY_RUN},\"rate_per_hr\":${RATE_PER_HR},\"stale_days\":${STALE_DAYS}"

exit 0
