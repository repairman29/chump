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

echo
echo "stale-gap-lock-reaper: reaped=$REAPED skipped=$SKIPPED errors=$ERRORS dry_run=$DRY_RUN"
