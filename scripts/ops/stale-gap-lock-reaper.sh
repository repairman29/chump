#!/usr/bin/env bash
# stale-gap-lock-reaper.sh — INFRA-676
#
# Sweeps .chump-locks/.gap-*.lock files whose owning session lease is gone.
# Companion to the in-process self-clean in try_claim_gap(): this catches
# orphaned locks from workers that were SIGKILLed or OOM-killed before they
# could clean up, and where no subsequent same-session claim has run.
#
# Logic per lock file:
#   1. Read first whitespace token → session_id
#   2. If .chump-locks/<session_id>.json exists → lease still active, SKIP
#   3. Else → no live lease for this session; delete the lock
#
# Usage:
#   ./scripts/ops/stale-gap-lock-reaper.sh              # dry-run (default)
#   ./scripts/ops/stale-gap-lock-reaper.sh --dry-run    # explicit dry-run
#   ./scripts/ops/stale-gap-lock-reaper.sh --execute    # actually delete
#
# LaunchAgent: dev.chump.stale-gap-lock-reaper (every 5 min)
#   Install: scripts/setup/install-stale-gap-lock-reaper-launchd.sh

set -euo pipefail

DRY_RUN=true
for arg in "$@"; do
    case "$arg" in
        --execute) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"

if [[ ! -d "$LOCK_DIR" ]]; then
    echo "lock dir not found: $LOCK_DIR — nothing to reap"
    exit 0
fi

REAPED=0
SKIPPED=0
ERRORS=0

for lock_file in "$LOCK_DIR"/.gap-*.lock; do
    [[ -e "$lock_file" ]] || continue

    # Extract session_id (first whitespace token in the file).
    session_id="$(awk 'NR==1{print $1; exit}' "$lock_file" 2>/dev/null || echo "")"
    if [[ -z "$session_id" ]]; then
        echo "  SKIP (unreadable): $lock_file"
        ERRORS=$((ERRORS+1))
        continue
    fi

    lease_file="$LOCK_DIR/${session_id}.json"
    if [[ -f "$lease_file" ]]; then
        # 2026-05-08 INFRA-732 extension: lease file present is NOT enough —
        # session_id encodes a PID (fleet-<...>-<PID>-<EPOCH>). If PID is
        # dead, the lease is a zombie and the lock should be reaped. Without
        # this check, the reaper missed the most common stall pattern (72
        # zombies observed mid-session, all had lease files but dead PIDs).
        pid=$(printf '%s' "$session_id" | grep -oE '[0-9]+-[0-9]+$' | cut -d- -f1)
        if [[ -n "$pid" ]] && ! ps -p "$pid" >/dev/null 2>&1; then
            # PID is dead — zombie. Reap both lock + lease.
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "  WOULD REAP (pid=$pid dead): $lock_file"
            else
                rm -f "$lock_file" "$lease_file"
                echo "  REAPED (pid=$pid dead): $lock_file + lease"
                printf '{"ts":"%s","kind":"stale_gap_lock_reaped","lock":"%s","session":"%s","reason":"pid_dead","pid":%d}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    "$(basename "$lock_file")" \
                    "$session_id" "$pid" \
                    >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            fi
            REAPED=$((REAPED+1))
            continue
        fi
        echo "  SKIP (live lease + live pid): $lock_file  [session=$session_id]"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  WOULD REAP: $lock_file  [session=$session_id, no lease found]"
    else
        rm -f "$lock_file"
        echo "  REAPED: $lock_file  [session=$session_id]"
        printf '{"ts":"%s","kind":"stale_gap_lock_reaped","lock":"%s","session":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(basename "$lock_file")" \
            "$session_id" \
            >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    fi
    REAPED=$((REAPED+1))
done


# ── INFRA-1017: sweep stale state.db leases rows ─────────────────────────────
# Vacuum rows whose expires_at is in the past (bot-merge killed before cleanup),
# or whose worktree path no longer exists (orphaned from a crashed session).
STATE_DB="${CHUMP_STATE_DB:-${REPO_ROOT}/.chump/state.db}"
DB_REAPED=0
if [[ -f "$STATE_DB" ]] && command -v sqlite3 &>/dev/null; then
    NOW_EPOCH="$(date +%s)"
    while IFS='|' read -r sid gid worktree expires_at; do
        [[ -z "$sid" ]] && continue
        reason=""
        if [[ "$expires_at" -lt "$NOW_EPOCH" ]]; then
            reason="expired"
        elif [[ -n "$worktree" && ! -d "$worktree" ]]; then
            reason="worktree_gone"
        fi
        [[ -z "$reason" ]] && continue

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  WOULD REAP state.db lease ($reason): session=$sid gap=$gid"
        else
            sqlite3 "$STATE_DB" \
                "DELETE FROM leases WHERE session_id='${sid}'" 2>/dev/null || true
            echo "  REAPED state.db lease ($reason): session=$sid gap=$gid"
            printf '{"ts":"%s","kind":"stale_gap_lock_reaped","session":"%s","gap":"%s","reason":"%s","source":"state.db"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "$gid" "$reason" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        fi
        DB_REAPED=$((DB_REAPED+1))
    done < <(sqlite3 "$STATE_DB" \
        "SELECT session_id,gap_id,worktree,expires_at FROM leases" 2>/dev/null || true)
fi

# ── INFRA-1164: sweep expired claim-*.json lease files ───────────────────────
# claim-*.json files are written by gap-claim.sh when a session claims a gap.
# They include an expires_at field. Sessions that crash or are killed without
# releasing leave orphaned claim files. This sweep reaps any claim file whose
# expires_at is in the past.
CLAIM_REAPED=0
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH_CLAIM="$(date -u +%s)"

for claim_file in "$LOCK_DIR"/claim-*.json; do
    [[ -e "$claim_file" ]] || continue
    # Parse expires_at from JSON
    expires_at="$(python3 -c "
import json, sys
try:
    d = json.load(open('$claim_file'))
    print(d.get('expires_at', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
    [[ -z "$expires_at" ]] && continue

    # Convert ISO timestamp to epoch
    expires_epoch="$(python3 -c "
import datetime
try:
    dt = datetime.datetime.fromisoformat('$expires_at'.replace('Z', '+00:00'))
    print(int(dt.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo "0")"

    # Parse session_id + gap_id once for both code paths below.
    session_id="$(python3 -c "
import json, sys
try:
    d = json.load(open('$claim_file'))
    print(d.get('session_id', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
    gap_id="$(python3 -c "
import json, sys
try:
    d = json.load(open('$claim_file'))
    print(d.get('gap_id', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"

    # INFRA-1221: open-PR protection. If this gap has an open PR, the work
    # is durable — leave the lease alone even if the claim is "expired" or
    # the originating PID is dead. The PR being open is enough signal
    # that another worker would just duplicate the work.
    if [[ -n "$gap_id" ]] && [[ -f "$REPO_ROOT/scripts/coord/lib/gap-pr-status.sh" ]]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/scripts/coord/lib/gap-pr-status.sh"
        if gap_has_open_pr "$gap_id" 2>/dev/null; then
            _pr_nums="$(gap_open_pr_number "$gap_id" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
            echo "  SKIP claim reap (open PR #$_pr_nums exists for gap=$gap_id): $(basename "$claim_file")"
            printf '{"ts":"%s","kind":"stale_gap_lock_skipped","reason":"open_pr_exists","gap":"%s","prs":"%s","lock":"%s"}\n' \
                "$NOW_ISO" "$gap_id" "$_pr_nums" "$(basename "$claim_file")" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            continue
        fi
    fi

    # INFRA-1208: PID-liveness check BEFORE TTL check. Sessions write 8h TTL
    # leases, but if a session crashes 30 min in, the existing TTL check
    # leaves the lease sitting for 7.5h+ — overnight accumulation of 14
    # dead leases observed 2026-05-14. session_id format is
    # claim-<gap>-<PID>-<EPOCH>. If PID is dead, reap immediately.
    claim_pid="$(printf '%s' "$session_id" | grep -oE '[0-9]+-[0-9]+$' | cut -d- -f1 2>/dev/null || echo "")"
    if [[ -n "$claim_pid" ]] && ! ps -p "$claim_pid" >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  WOULD REAP claim (pid=$claim_pid dead): $(basename "$claim_file") [gap=$gap_id]"
        else
            rm -f "$claim_file"
            echo "  REAPED claim (pid=$claim_pid dead): $(basename "$claim_file") [gap=$gap_id]"
            printf '{"ts":"%s","kind":"stale_gap_lock_reaped","event":"stale_gap_lock_reaped","lock":"%s","session":"%s","gap":"%s","reason":"pid_dead","pid":%d,"source":"claim_file"}\n' \
                "$NOW_ISO" \
                "$(basename "$claim_file")" \
                "$session_id" "$gap_id" "$claim_pid" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        fi
        CLAIM_REAPED=$((CLAIM_REAPED+1))
        continue
    fi

    if [[ "$expires_epoch" -gt 0 && "$expires_epoch" -lt "$NOW_EPOCH_CLAIM" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  WOULD REAP claim (expired $expires_at): $(basename "$claim_file") [gap=$gap_id]"
        else
            rm -f "$claim_file"
            echo "  REAPED claim (expired $expires_at): $(basename "$claim_file") [gap=$gap_id]"
            printf '{"ts":"%s","kind":"stale_gap_lock_reaped","event":"stale_gap_lock_reaped","lock":"%s","session":"%s","gap":"%s","reason":"expired","source":"claim_file"}\n' \
                "$NOW_ISO" \
                "$(basename "$claim_file")" \
                "$session_id" "$gap_id" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        fi
        CLAIM_REAPED=$((CLAIM_REAPED+1))
    fi
done

echo
echo "stale-gap-lock-reaper: reaped=$REAPED skipped=$SKIPPED errors=$ERRORS dry_run=$DRY_RUN db_reaped=$DB_REAPED claim_reaped=$CLAIM_REAPED"
