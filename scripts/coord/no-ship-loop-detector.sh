#!/usr/bin/env bash
# scripts/coord/no-ship-loop-detector.sh — RESILIENT-1573
#
# Harness-agnostic belt-and-suspenders loop detector. Consumes signals the
# worker already emits (ambient cycle_end) plus systemd NRestarts, so a buggy
# worker-internal counter (INFRA-3832 / EFFECTIVE-441 / RESILIENT-1572) cannot
# hide a silent loop.
#
#  Pass 1: group cycle_end by gap_id. >= N (default 5) bad cycles
#          (unverified_ship|failed|timeout|wedge) with zero `shipped` after the
#          last ship => set the gap blocked + dep-gate note, emit
#          no_ship_loop_detected, file ONE follow-up gap per gap_id. The block
#          is re-asserted on every tick while the gap keeps being re-picked
#          (new bad cycles since last block), so the stuck-pr-filer auto-flip
#          to open cannot defeat it.
#  Pass 2: systemctl show NRestarts for user AND system scope units; over
#          threshold => emit service_crash_loop + file/alarm once per unit
#          (covers the systemd blind spot of daemon-exit-loop-watcher, RESILIENT-1571).
#
# scanner-anchor: "kind":"no_ship_loop_detected"
# scanner-anchor: "kind":"service_crash_loop"
#
# Usage: no-ship-loop-detector.sh [tick]
# Env: CHUMP_NSL_DISABLED, CHUMP_NSL_THRESHOLD(5), CHUMP_NSL_WINDOW_LINES(5000),
#      CHUMP_NSL_NRESTARTS_THRESHOLD(20), CHUMP_NSL_STATE_FILE, CHUMP_NSL_DRY_RUN,
#      CHUMP_NSL_CHUMP_CMD, CHUMP_NSL_SYSTEMCTL (mock), CHUMP_AMBIENT_PATH

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
THRESHOLD="${CHUMP_NSL_THRESHOLD:-5}"
WINDOW="${CHUMP_NSL_WINDOW_LINES:-5000}"
NR_THRESHOLD="${CHUMP_NSL_NRESTARTS_THRESHOLD:-20}"
STATE_FILE="${CHUMP_NSL_STATE_FILE:-$REPO_ROOT/.chump/no-ship-loop-state.json}"
DRY_RUN="${CHUMP_NSL_DRY_RUN:-}"
CHUMP_BIN="${CHUMP_NSL_CHUMP_CMD:-chump}"
SYSTEMCTL="${CHUMP_NSL_SYSTEMCTL:-systemctl}"

log() { printf '[no-ship-loop-detector] %s\n' "$*" >&2; }
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { sed -n 2,24p "$0"; exit 0; }
[[ -n "${CHUMP_NSL_DISABLED:-}" ]] && { log "disabled"; exit 0; }
command -v jq >/dev/null 2>&1 || { log "jq required"; exit 0; }

mkdir -p "$(dirname "$AMBIENT")" "$(dirname "$STATE_FILE")" 2>/dev/null || true
[[ -f "$STATE_FILE" ]] || printf '{}\n' > "$STATE_FILE"

emit() { # kind json-fields
    printf '{"ts":"%s","kind":"%s","dry_run":%s,%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
        "$([[ -n "$DRY_RUN" ]] && echo true || echo false)" "$2" >> "$AMBIENT"
}
state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null; }
state_set() {
    local tmp; tmp="$(mktemp)"
    jq --arg k "$1" --argjson v "$2" '.[$k]=$v' "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || rm -f "$tmp"
}

# ── Pass 1: no-ship loops ────────────────────────────────────────────────────
if [[ -f "$AMBIENT" ]]; then
    # one line per gap: gap_id <TAB> bad_since_last_ship
    tail -n "$WINDOW" "$AMBIENT" | jq -rRs '
        [split("\n")[] | (try fromjson catch empty)
         | select((.event // .kind) == "cycle_end" and ((.gap_id // "") != ""))]
        | group_by(.gap_id)[]
        | .[0].gap_id as $g
        | (reduce .[] as $c (0;
              ($c.kind // $c.cycle_kind // "") as $k
              | if $k == "shipped" then 0
                elif ($k == "unverified_ship" or $k == "failed" or $k == "timeout" or $k == "wedge") then . + 1
                else . end)) as $bad
        | select($bad > 0) | "\($g)\t\($bad)"' 2>/dev/null |
    while IFS=$'\t' read -r gap bad; do
        [[ -n "$gap" ]] || continue
        (( bad >= THRESHOLD )) || continue
        prev="$(state_get "blocked:$gap")"
        if [[ -n "$prev" ]]; then
            # already handled; re-assert only on new bad cycles (re-pick after auto-flip)
            (( bad > prev )) || continue
        fi
        log "no-ship loop: $gap bad_cycles=$bad"
        emit no_ship_loop_detected "\"gap_id\":\"$gap\",\"bad_cycles\":$bad,\"threshold\":$THRESHOLD,\"reblock\":$([[ -n "$prev" ]] && echo true || echo false)"
        [[ -n "$DRY_RUN" ]] && continue
        "$CHUMP_BIN" gap set "$gap" --status blocked \
            --add-note "no-ship-loop-detector (RESILIENT-1573): $bad consecutive non-shipped cycles (>= $THRESHOLD); auto-blocked. dep-gate: do not re-pick until root cause fixed" \
            >/dev/null 2>&1 || log "WARN: could not block $gap"
        if [[ -z "$(state_get "filed:$gap")" ]]; then
            "$CHUMP_BIN" gap reserve --domain RESILIENT --priority P2 --no-outcome-required \
                --title "RESILIENT: no-ship loop on $gap ($bad non-shipped cycles) — find root cause" \
                >/dev/null 2>&1 && state_set "filed:$gap" true
        fi
        state_set "blocked:$gap" "$bad"
    done
fi

# ── Pass 2: systemd crash loops ──────────────────────────────────────────────
if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    for scope in user system; do
        flag=(); [[ "$scope" == user ]] && flag=(--user)
        "$SYSTEMCTL" "${flag[@]}" list-units --type=service --all --plain --no-legend --no-pager 2>/dev/null |
            awk '{print $1}' | grep -E '\.service$' |
        while read -r unit; do
            n="$("$SYSTEMCTL" "${flag[@]}" show "$unit" -p NRestarts --value 2>/dev/null | head -1)"
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            (( n >= NR_THRESHOLD )) || continue
            key="crash:$scope:$unit"
            prev="$(state_get "$key")"
            [[ -n "$prev" ]] && (( n <= prev )) && continue
            log "crash loop: $scope/$unit NRestarts=$n"
            emit service_crash_loop "\"unit\":\"$unit\",\"scope\":\"$scope\",\"nrestarts\":$n,\"threshold\":$NR_THRESHOLD"
            [[ -n "$DRY_RUN" ]] && continue
            if [[ -z "$prev" ]]; then
                "$CHUMP_BIN" gap reserve --domain RESILIENT --priority P1 --no-outcome-required \
                    --title "RESILIENT: systemd $scope service $unit crash-looping (NRestarts=$n)" \
                    >/dev/null 2>&1 || true
            fi
            state_set "$key" "$n"
        done
    done
fi
exit 0
