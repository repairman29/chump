#!/usr/bin/env bash
# gap-gardener.sh — INFRA-964 / INFRA-841
#
# Daily gap-store hygiene run by `chump fleet daemon` every 24h.
# Never requires operator intervention — does what an operator would
# otherwise do by hand:
#
#   1. Stale-lease sweep — force-release leases expired or dead-heartbeat > 4h
#   2. Done-gap worktree prune — remove /private/tmp/chump-<id> for done gaps
#      (skips any with active leases)
#   3. Vague-AC alert — emit kind=vague_ac_alert for each open P1 gap with
#      no acceptance_criteria (does NOT auto-fill; operator decides content)
#   4. P0 inflation alert — emit kind=p0_inflation_alert when P0 count > 5
#   5. Emit kind=gap_gardener_run summary with counts
#
# All actions are logged to ambient.jsonl. Destructive actions (lease
# force-release, worktree removal) are logged individually before execution.
# Idempotent: safe to run multiple times.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
STATE_DB="$REPO_ROOT/.chump/state.db"
NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$LOCK_DIR"

emit() {
    local kind="$1" payload="$2"
    printf '{"ts":"%s","kind":"%s",%s}\n' "$NOW_ISO" "$kind" "$payload" \
        >> "$AMBIENT_LOG"
}

leases_released=0
worktrees_pruned=0
vague_ac_count=0
p0_count=0

# ── 1. Stale-lease sweep ─────────────────────────────────────────────────────
# A lease is stale if:
#   (a) its expires_at is in the past, OR
#   (b) its heartbeat_at matches taken_at (never updated) AND taken_at > 4h ago
FOUR_H_AGO=$((NOW_EPOCH - 14400))

for lease_file in "$LOCK_DIR"/claim-*.json; do
    [ -f "$lease_file" ] || continue
    gap_id=$(python3 -c "import json,sys; d=json.load(open('$lease_file')); print(d.get('gap_id',''))" 2>/dev/null)
    expires_raw=$(python3 -c "import json,sys; d=json.load(open('$lease_file')); print(d.get('expires_at',''))" 2>/dev/null)
    taken_raw=$(python3 -c "import json,sys; d=json.load(open('$lease_file')); print(d.get('taken_at',''))" 2>/dev/null)
    heartbeat_raw=$(python3 -c "import json,sys; d=json.load(open('$lease_file')); print(d.get('heartbeat_at',''))" 2>/dev/null)

    [ -z "$gap_id" ] && continue

    # python3 handles the Z suffix correctly on both macOS and Linux
    iso_to_epoch() {
        python3 -c "
import sys, datetime, calendar
s = sys.argv[1].rstrip('Z')
try:
    dt = datetime.datetime.fromisoformat(s)
except Exception:
    print(0); sys.exit(0)
print(int(calendar.timegm(dt.timetuple())))
" "${1:-}" 2>/dev/null || echo 0
    }

    expires_epoch=$(iso_to_epoch "$expires_raw")
    taken_epoch=$(iso_to_epoch "$taken_raw")
    heartbeat_epoch=$(iso_to_epoch "$heartbeat_raw")

    stale=0
    reason=""
    # (a) expired
    if [ "$expires_epoch" -gt 0 ] && [ "$NOW_EPOCH" -gt "$expires_epoch" ]; then
        stale=1
        reason="expired_at_${expires_raw}"
    # (b) no heartbeat update in 4h
    elif [ "$heartbeat_epoch" -gt 0 ] && [ "$heartbeat_epoch" = "$taken_epoch" ] \
         && [ "$taken_epoch" -lt "$FOUR_H_AGO" ]; then
        stale=1
        reason="heartbeat_frozen_since_taken_at_${taken_raw}"
    fi

    if [ "$stale" -eq 1 ]; then
        emit "lease_force_released" \
            "\"gap_id\":\"$gap_id\",\"reason\":\"$reason\",\"operator\":\"gap-gardener\""
        rm -f "$lease_file"
        leases_released=$((leases_released + 1))
    fi
done

# ── 2. Done-gap worktree prune ───────────────────────────────────────────────
# Build the set of active-lease gap slugs so we don't prune them.
active_slugs=""
for lf in "$LOCK_DIR"/claim-*.json; do
    [ -f "$lf" ] || continue
    slug=$(basename "$lf" | grep -oE 'claim-[a-z]+-[0-9]+' | sed 's/claim-//' || true)
    active_slugs="$active_slugs $slug"
done

if [ -f "$STATE_DB" ]; then
    while IFS= read -r gid; do
        wt="/private/tmp/chump-${gid}"
        [ -d "$wt" ] || continue
        # Skip if there's an active lease for this gap
        if echo "$active_slugs" | grep -q "\b${gid}\b"; then
            continue
        fi
        emit "worktree_pruned" \
            "\"gap_id\":\"$(echo $gid | tr '[:lower:]' '[:upper:]' | sed 's/-[0-9]/-&/;s/^//' )\",\"path\":\"$wt\",\"operator\":\"gap-gardener\""
        git worktree remove "$wt" --force 2>/dev/null || rm -rf "$wt"
        worktrees_pruned=$((worktrees_pruned + 1))
    done < <(sqlite3 "$STATE_DB" "SELECT lower(id) FROM gaps WHERE status='done';" 2>/dev/null)
fi

# ── 3. Vague-AC alert ────────────────────────────────────────────────────────
if [ -f "$STATE_DB" ]; then
    while IFS=$'\t' read -r gid title; do
        emit "vague_ac_alert" \
            "\"gap_id\":\"$gid\",\"title\":\"$(echo "$title" | sed 's/"/\\"/g')\",\"hint\":\"add concrete acceptance_criteria before claiming\""
        vague_ac_count=$((vague_ac_count + 1))
    done < <(sqlite3 "$STATE_DB" \
        "SELECT id, title FROM gaps WHERE status='open' AND priority IN ('P0','P1') \
         AND (acceptance_criteria IS NULL OR acceptance_criteria='[]' OR acceptance_criteria='');" \
        2>/dev/null)
fi

# ── 4. P0 inflation alert ────────────────────────────────────────────────────
if [ -f "$STATE_DB" ]; then
    p0_count=$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE status='open' AND priority='P0';" 2>/dev/null || echo 0)
    if [ "$p0_count" -gt 5 ]; then
        emit "p0_inflation_alert" \
            "\"count\":$p0_count,\"limit\":5,\"hint\":\"demote non-critical P0s to P1 — CLAUDE.md cap is 5\""
    fi
fi

# ── 5. Summary ───────────────────────────────────────────────────────────────
emit "gap_gardener_run" \
    "\"leases_released\":$leases_released,\"worktrees_pruned\":$worktrees_pruned,\"vague_ac_alerts\":$vague_ac_count,\"p0_count\":$p0_count"

echo "[gap-gardener] done: leases_released=$leases_released worktrees_pruned=$worktrees_pruned vague_ac_alerts=$vague_ac_count p0_count=$p0_count"
