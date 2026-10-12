#!/usr/bin/env bash
# scripts/coord/no-ship-loop-detector.sh — RESILIENT-1573
#
# Harness-agnostic belt-and-suspenders loop detector (launchd + systemd).
#  Pass 1: consumes ambient cycle_end events; a gap with >= N non-shipped
#          cycles (unverified_ship|failed|timeout|wedge) and zero shipped is
#          set status=blocked + noted, and ONE gap is filed per looping gap.
#          Re-blocks on every later observed re-pick (immune to auto-flip).
#  Pass 2: systemd NRestarts (user + system scope) over threshold -> alarm +
#          one gap per unit.
#
# scanner-anchor: "kind":"no_ship_loop_detected"
# scanner-anchor: "kind":"service_crash_loop"
#
# Env: CHUMP_NO_SHIP_LOOP_DISABLED, CHUMP_NO_SHIP_LOOP_THRESHOLD (5),
#      CHUMP_NO_SHIP_LOOP_WINDOW_LINES (50000), CHUMP_SERVICE_CRASH_THRESHOLD (50),
#      CHUMP_NO_SHIP_LOOP_STATE_FILE, CHUMP_NO_SHIP_LOOP_DRY_RUN,
#      CHUMP_AMBIENT_PATH, CHUMP_NO_SHIP_LOOP_CHUMP_CMD, CHUMP_NO_SHIP_LOOP_SYSTEMCTL

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
STATE_FILE="${CHUMP_NO_SHIP_LOOP_STATE_FILE:-$REPO_ROOT/.chump/no-ship-loop-state.json}"
THRESHOLD="${CHUMP_NO_SHIP_LOOP_THRESHOLD:-5}"
WINDOW="${CHUMP_NO_SHIP_LOOP_WINDOW_LINES:-50000}"
CRASH_THRESHOLD="${CHUMP_SERVICE_CRASH_THRESHOLD:-50}"
DRY_RUN="${CHUMP_NO_SHIP_LOOP_DRY_RUN:-}"
CHUMP_BIN="${CHUMP_NO_SHIP_LOOP_CHUMP_CMD:-chump}"
SYSTEMCTL="${CHUMP_NO_SHIP_LOOP_SYSTEMCTL:-systemctl}"

[[ "${1:-}" == "--help" ]] && { sed -n '2,15p' "$0"; exit 0; }
[[ -n "${CHUMP_NO_SHIP_LOOP_DISABLED:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || { echo "[no-ship-loop] jq required" >&2; exit 0; }

mkdir -p "$(dirname "$AMBIENT")" "$(dirname "$STATE_FILE")" 2>/dev/null || true
log() { printf '[no-ship-loop] %s\n' "$*" >&2; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { printf '%s\n' "$1" >> "$AMBIENT"; }

STATE='{}'
[[ -f "$STATE_FILE" ]] && STATE="$(cat "$STATE_FILE" 2>/dev/null)"
printf '%s' "$STATE" | jq -e . >/dev/null 2>&1 || STATE='{}'

file_gap() {  # title -> prints gap id (best effort)
    [[ -n "$DRY_RUN" ]] && return 0
    "$CHUMP_BIN" gap reserve --domain RESILIENT --title "$1" 2>/dev/null | grep -Eo '[A-Z]+-[0-9]+' | head -1
}

# ── Pass 1: no-ship loops ────────────────────────────────────────────────────
if [[ -f "$AMBIENT" ]]; then
    LOOPS="$(tail -n "$WINDOW" "$AMBIENT" | jq -Rrs --argjson n "$THRESHOLD" --argjson st "$STATE" '
        [split("\n")[] | (try fromjson catch empty)
         | select(.event == "cycle_end" and ((.gap_id // "") != ""))] as $c
        | ($c | group_by(.gap_id))[]
        | . as $g | $g[0].gap_id as $id
        | ($st[$id].blocked_ts // "") as $since
        | [$g[] | select(.ts > $since)] as $new
        | ($new | map(select(.kind == "shipped")) | length) as $shipped
        | ($new | map(select(.kind | IN("unverified_ship","failed","timeout","wedge"))) | length) as $bad
        | select($shipped == 0 and $bad >= (if $since == "" then $n else 1 end))
        | "\($id)\t\($bad)\t\($new | map(.ts) | max)"')"
    while IFS=$'\t' read -r gid bad last_ts; do
        [[ -z "$gid" ]] && continue
        known="$(printf '%s' "$STATE" | jq -r --arg g "$gid" '.[$g].filed // ""')"
        log "loop: $gid bad_cycles=$bad"
        filed="$known"
        if [[ -z "$DRY_RUN" ]]; then
            "$CHUMP_BIN" gap set "$gid" --status blocked \
                --add-note "no-ship-loop-detector (RESILIENT-1573): $bad non-shipped cycles, zero shipped. dep-gate: blocked until root cause fixed; re-blocked on each re-pick." >/dev/null 2>&1 || true
            if [[ -z "$known" ]]; then
                filed="$(file_gap "Investigate no-ship loop on $gid ($bad non-shipped worker cycles)")"
                filed="${filed:-filed}"
            fi
        fi
        emit "{\"ts\":\"$(ts)\",\"kind\":\"no_ship_loop_detected\",\"gap_id\":\"$gid\",\"bad_cycles\":$bad,\"filed_gap\":\"$filed\",\"dry_run\":$([[ -n $DRY_RUN ]] && echo true || echo false)}"
        STATE="$(printf '%s' "$STATE" | jq --arg g "$gid" --arg t "$last_ts" --arg f "$filed" '.[$g]={blocked_ts:$t,filed:$f}')"
    done <<< "$LOOPS"
fi

# ── Pass 2: systemd crash loops ──────────────────────────────────────────────
if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    for scope in user system; do
        flag=(); [[ "$scope" == user ]] && flag=(--user)
        while read -r unit; do
            [[ -z "$unit" ]] && continue
            n="$("$SYSTEMCTL" "${flag[@]}" show "$unit" -p NRestarts --value 2>/dev/null | head -1)"
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            (( n >= CRASH_THRESHOLD )) || continue
            key="svc:$scope:$unit"
            prev="$(printf '%s' "$STATE" | jq -r --arg k "$key" '.[$k].filed // ""')"
            [[ -n "$prev" ]] && continue
            log "crash loop: $scope/$unit NRestarts=$n"
            filed="$(file_gap "Service crash-loop: $unit ($scope scope) NRestarts=$n")"
            filed="${filed:-filed}"
            emit "{\"ts\":\"$(ts)\",\"kind\":\"service_crash_loop\",\"unit\":\"$unit\",\"scope\":\"$scope\",\"nrestarts\":$n,\"filed_gap\":\"$filed\"}"
            STATE="$(printf '%s' "$STATE" | jq --arg k "$key" --arg f "$filed" '.[$k]={filed:$f}')"
        done < <("$SYSTEMCTL" "${flag[@]}" list-units --type=service --state=activating,failed,active --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -E '\.service$')
    done
fi

printf '%s\n' "$STATE" > "$STATE_FILE"
exit 0
