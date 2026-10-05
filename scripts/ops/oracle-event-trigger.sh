#!/usr/bin/env bash
# scripts/ops/oracle-event-trigger.sh — INFRA-2123
#
# Event-driven Oracle refresh. The existing scripts/coord/oracle-refresh.sh
# only fires on a 4h launchd cadence (META-088), so a burst of newly-filed
# gaps (e.g. an operator/curator filing 5 CI-review levers back to back)
# waits up to 4h before Oracle re-ranks docs/process/THE_PATH.md against
# them. This script closes that gap: tail ambient.jsonl, count
# kind=gap_reserved events since the last completed Oracle refresh, and
# force a refresh once CHUMP_ORACLE_GAP_THRESHOLD new gaps have piled up.
#
# Depends on INFRA-2122 (Oracle silent-staleness fix) — that lands first so
# an event-driven burst can't amplify a silently-failing refresh loop.
#
# Usage:
#   scripts/ops/oracle-event-trigger.sh            # check + maybe trigger
#   scripts/ops/oracle-event-trigger.sh --dry-run   # log verdict, never fire
#
# Env:
#   CHUMP_ORACLE_GAP_THRESHOLD   gap_reserved count to trigger (default 5)
#   CHUMP_ORACLE_COALESCE_S      min seconds since last refresh run before
#                                 an event-driven trigger is allowed
#                                 (default 3600 = 1h, per AC4 dedup)
#   CHUMP_AMBIENT_LOG            path to ambient.jsonl
#                                 (default .chump-locks/ambient.jsonl)
#   CHUMP_ORACLE_DISABLED=1      short-circuit (shared with oracle-refresh.sh)

set -uo pipefail

[[ "${CHUMP_ORACLE_DISABLED:-0}" == "1" ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REFRESH_SCRIPT="$REPO_ROOT/scripts/coord/oracle-refresh.sh"
THRESHOLD="${CHUMP_ORACLE_GAP_THRESHOLD:-5}"
COALESCE_S="${CHUMP_ORACLE_COALESCE_S:-3600}"

DRY_RUN=0
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

emit_ambient() {
    local kind="$1" payload="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$payload" >> "$AMBIENT" 2>/dev/null || true
}

if [[ ! -f "$AMBIENT" ]]; then
    echo "[oracle-event-trigger] no ambient.jsonl at $AMBIENT; nothing to count"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[oracle-event-trigger] jq not available; skipping" >&2
    exit 0
fi

# "Last completed refresh" = most recent oracle_refresh_drift or
# oracle_refresh_noop event — the two outcomes that mean the burst actually
# ran to completion (as opposed to _failed/_empty/_skipped). No such event
# on record means "since the beginning of the log".
last_refresh_ts="$(jq -rs '
    map(select(.kind == "oracle_refresh_drift" or .kind == "oracle_refresh_noop") | .ts)
    | sort
    | last // empty
' "$AMBIENT" 2>/dev/null)"

# "Last run at all" (any outcome, including failed/skipped/empty) — this is
# the cadence coalescing anchor: if oracle-refresh.sh executed at all within
# the last CHUMP_ORACLE_COALESCE_S seconds, don't double-burst on top of it.
last_run_ts="$(jq -rs '
    map(select(.kind | startswith("oracle_refresh_")) | .ts)
    | sort
    | last // empty
' "$AMBIENT" 2>/dev/null)"

now_s="$(date -u +%s)"

gap_count="$(jq -rs --arg since "${last_refresh_ts:-1970-01-01T00:00:00Z}" '
    map(select(.kind == "gap_reserved" and .ts > $since))
    | length
' "$AMBIENT" 2>/dev/null)"
gap_count="${gap_count:-0}"

echo "[oracle-event-trigger] gap_reserved since last refresh (${last_refresh_ts:-none}): ${gap_count} (threshold=${THRESHOLD})"

if [[ "$gap_count" -lt "$THRESHOLD" ]]; then
    exit 0
fi

if [[ -n "${last_run_ts:-}" ]]; then
    last_run_s="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_run_ts" +%s 2>/dev/null || date -u -d "$last_run_ts" +%s 2>/dev/null || echo 0)"
    age_s=$(( now_s - last_run_s ))
    if [[ "$age_s" -lt "$COALESCE_S" ]]; then
        echo "[oracle-event-trigger] threshold met (${gap_count} >= ${THRESHOLD}) but last refresh ran ${age_s}s ago (< ${COALESCE_S}s coalesce window); skipping"
        # scanner-anchor: "kind":"oracle_event_trigger_coalesced"
        emit_ambient "oracle_event_trigger_coalesced" "\"gap_count\":${gap_count},\"threshold\":${THRESHOLD},\"last_run_age_s\":${age_s},\"coalesce_s\":${COALESCE_S}"
        exit 0
    fi
fi

echo "[oracle-event-trigger] threshold met (${gap_count} >= ${THRESHOLD}); triggering oracle-refresh.sh --force"
# scanner-anchor: "kind":"oracle_event_trigger_fired"
emit_ambient "oracle_event_trigger_fired" "\"gap_count\":${gap_count},\"threshold\":${THRESHOLD}"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "[oracle-event-trigger] --dry-run set; not invoking oracle-refresh.sh"
    exit 0
fi

[[ -x "$REFRESH_SCRIPT" ]] || { echo "[oracle-event-trigger] missing/non-executable: $REFRESH_SCRIPT" >&2; exit 0; }

bash "$REFRESH_SCRIPT" --force
exit 0
