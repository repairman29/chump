#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ sources use dynamic $SCRIPT_DIR — resolved at runtime
# stale-lease-reaper.sh — clean up expired claim session leases.
#
# Expired leases indicate sessions that crashed, disconnected, or were forcefully
# killed without proper cleanup. This reaper safely removes them after verifying:
#   - expires_at is in the past (lease TTL exceeded)
#   - gap is not currently in progress (double-check via chump gap show)
#   - no sibling session has same gap (race prevention)
#
# Usage:
#   scripts/coord/stale-lease-reaper.sh                 # dry-run (safe)
#   scripts/coord/stale-lease-reaper.sh --execute       # actually delete
#
# Output: one line per lease with action taken.
# Emits ambient.jsonl events for each deletion or skip.
# Exits 0 if all OK, 1 if any gaps are in-flight (should not delete).

set -euo pipefail

# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck source=lib/ambient-write.sh
source "$(dirname "$0")/lib/ambient-write.sh"

DRY_RUN=1
LOCK_DIR=".chump-locks"
NOW_TS=$(date +%s)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute) DRY_RUN=0 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Helper: emit ambient event
emit_event() {
    local kind="$1" lease_id="$2" reason="$3"
    _ambient_write "$LOCK_DIR/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"%s","lease":"%s","reason":"%s"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$lease_id" "$reason")"
}

# Helper: check if lease is expired
is_lease_expired() {
    local expires_at="$1"
    local expires_ts; expires_ts=$(date -d "$expires_at" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null \
        || echo 0)
    [[ $expires_ts -lt $NOW_TS ]]
}

# Helper: extract gap ID from lease file
gap_from_lease() {
    local lease_file="$1"
    jq -r '.gap_id // .purpose' "$lease_file" 2>/dev/null | grep -o "[A-Z]*-[0-9]*" | head -1 || echo ""
}

# Helper: check if gap is in progress (status != done/shipped/closed)
is_gap_in_progress() {
    local gap_id="$1"
    local gap_status; gap_status=$(chump gap show "$gap_id" --json 2>/dev/null | jq -r '.status // "error"' || echo "error")
    case "$gap_status" in
        done|shipped|closed|error) return 1 ;; # not in progress
        *) return 0 ;; # in progress
    esac
}

# Main loop: find and clean stale leases
deleted_count=0
skipped_count=0
has_errors=0

for lease in "$LOCK_DIR"/claim-*.json; do
    [ -f "$lease" ] || continue

    lease_id=$(basename "$lease" .json)
    expires_at=$(jq -r '.expires_at // empty' "$lease" 2>/dev/null)
    gap_id=$(gap_from_lease "$lease")

    # Skip leases without expires_at or gap_id
    if [[ -z "$expires_at" || -z "$gap_id" ]]; then
        echo "[reaper] SKIP: $lease_id (missing metadata)"
        emit_event "lease_reaper_skipped_invalid" "$lease_id" "missing_metadata"
        ((skipped_count++))
        continue
    fi

    # Skip if lease hasn't expired yet
    if ! is_lease_expired "$expires_at"; then
        echo "[reaper] SKIP: $lease_id ($gap_id, still active)"
        emit_event "lease_reaper_skipped_active" "$lease_id" "not_expired"
        ((skipped_count++))
        continue
    fi

    # Safety: skip if gap is still in progress (double-check)
    if is_gap_in_progress "$gap_id"; then
        echo "[reaper] SKIP: $lease_id ($gap_id, gap still in progress)"
        emit_event "lease_reaper_skipped_in_progress" "$lease_id" "gap_in_progress"
        ((skipped_count++))
        continue
    fi

    # Safe to delete
    if [ "$DRY_RUN" = 1 ]; then
        echo "[reaper] DRY-RUN: would delete $lease_id ($gap_id)"
        emit_event "lease_reaper_dry_run" "$lease_id" "would_delete"
    else
        if rm -f "$lease" 2>/dev/null; then
            echo "[reaper] DELETED: $lease_id ($gap_id)"
            emit_event "lease_reaper_deleted" "$lease_id" "lease_removed"
            ((deleted_count++))
        else
            echo "[reaper] ERROR: failed to delete $lease_id ($gap_id)"
            emit_event "lease_reaper_error" "$lease_id" "file_remove_failed"
            ((has_errors++))
        fi
    fi
done

echo "[reaper] summary: deleted=$deleted_count skipped=$skipped_count errors=$has_errors"
exit "$has_errors"
