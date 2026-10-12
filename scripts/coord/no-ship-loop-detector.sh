#!/usr/bin/env bash
# scripts/coord/no-ship-loop-detector.sh — RESILIENT-1573
#
# Harness-agnostic belt-and-suspenders detector for two silent-loop classes:
#   (1) no-ship loop: a gap picked >=N times in a row (cycle_end kind in
#       unverified_ship/failed/timeout/wedge, zero shipped since) → gap is set
#       blocked + dep-gate note + ONE gap filed. Re-blocks on every NEW
#       observed re-pick, so the stuck-pr-filer auto-flip cannot un-wedge it.
#   (2) service crash-loop: systemd NRestarts (user AND system scope) over a
#       threshold → service_crash_loop + ONE gap filed (covers the systemd
#       blind spot of the launchd-only daemon-exit-loop-watcher, RESILIENT-1571).
#
# scanner-anchor: "kind":"no_ship_loop_detected"
# scanner-anchor: "kind":"service_crash_loop"
#
# Usage: no-ship-loop-detector.sh [tick]
# Env (optional):
#   CHUMP_NO_SHIP_LOOP_DISABLED     non-empty → exit 0
#   CHUMP_NO_SHIP_LOOP_THRESHOLD    bad cycles with zero ships to trigger (default 5)
#   CHUMP_NO_SHIP_LOOP_TAIL_LINES   ambient lines scanned (default 50000)
#   CHUMP_NO_SHIP_LOOP_DRY_RUN      non-empty → no chump writes
#   CHUMP_NO_SHIP_LOOP_STATE_FILE   dedup state JSON (default $REPO/.chump/no-ship-loop-state.json)
#   CHUMP_CRASH_LOOP_THRESHOLD      NRestarts that triggers an alarm (default 50)
#   CHUMP_CRASH_LOOP_UNIT_GLOB      unit-name glob (default 'chump*')
#   CHUMP_CRASH_LOOP_SYSTEMCTL      systemctl binary (default systemctl; test mock)
#   CHUMP_AMBIENT_PATH / CHUMP_AMBIENT_LOG   ambient.jsonl override

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
STATE_FILE="${CHUMP_NO_SHIP_LOOP_STATE_FILE:-$REPO_ROOT/.chump/no-ship-loop-state.json}"
THRESHOLD="${CHUMP_NO_SHIP_LOOP_THRESHOLD:-5}"
TAIL_LINES="${CHUMP_NO_SHIP_LOOP_TAIL_LINES:-50000}"
DRY_RUN="${CHUMP_NO_SHIP_LOOP_DRY_RUN:-}"
CRASH_THRESHOLD="${CHUMP_CRASH_LOOP_THRESHOLD:-50}"
UNIT_GLOB="${CHUMP_CRASH_LOOP_UNIT_GLOB:-chump*}"
SYSTEMCTL="${CHUMP_CRASH_LOOP_SYSTEMCTL:-systemctl}"
CHUMP_BIN="${CHUMP_NO_SHIP_LOOP_CHUMP_CMD:-chump}"

case "${1:-tick}" in
    tick) ;;
    -h|--help) sed -n 2,26p "$0"; exit 0 ;;
    *) echo "usage: $0 [tick]" >&2; exit 2 ;;
esac

[[ -n "${CHUMP_NO_SHIP_LOOP_DISABLED:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || { echo "[no-ship-loop] jq required" >&2; exit 0; }

mkdir -p "$(dirname "$AMBIENT")" "$(dirname "$STATE_FILE")" 2>/dev/null || true

log() { printf '[no-ship-loop] %s\n' "$*" >&2; }
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# emit <kind> <jq-args-json-object>
emit() {
    jq -cn --arg ts "$(_ts)" --arg kind "$1" --argjson x "$2" \
        '{ts:$ts,kind:$kind} + $x' >> "$AMBIENT"
}

STATE="$( [[ -f "$STATE_FILE" ]] && jq -c . "$STATE_FILE" 2>/dev/null || true )"
[[ -n "$STATE" ]] || STATE='{}'
save_state() { printf '%s\n' "$STATE" > "$STATE_FILE"; }

file_gap() { # file_gap <title> <description>
    [[ -n "$DRY_RUN" ]] && { log "dry-run: would file gap: $1"; return 0; }
    "$CHUMP_BIN" gap reserve --domain RESILIENT --priority P2 --title "$1" \
        --description "$2" >/dev/null 2>&1 \
        || log "gap reserve failed for: $1"
}

# ── (1) no-ship loops ────────────────────────────────────────────────────────
# Accepts both {"event":"cycle_end",...} (worker.sh) and {"kind":"cycle_end"}.
# Output per looping gap: {gap_id,count,last_ts,last_kind}
loops="$(tail -n "$TAIL_LINES" "$AMBIENT" 2>/dev/null | jq -cs --argjson n "$THRESHOLD" '
    [ .[] | select(type=="object")
          | select((.event // "")=="cycle_end" or (.kind // "")=="cycle_end")
          | select((.gap_id // "") != "") ]
    | group_by(.gap_id)
    | map(
        . as $g
        | ($g | map(select(.kind=="shipped" or .cycle_kind=="shipped"))
              | map(.ts) | max // "") as $last_ship
        | [ $g[] | select(.ts > $last_ship)
              | select((.cycle_kind // .kind) as $k
                       | ["unverified_ship","failed","timeout","wedge"] | index($k)) ] as $bad
        | { gap_id: $g[0].gap_id, count: ($bad|length),
            last_ts: ($bad | map(.ts) | max // ""),
            last_kind: (($bad | last | (.cycle_kind // .kind)) // "") } )
    | map(select(.count >= $n)) | .[]' 2>/dev/null || true)"

while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    gap="$(jq -r .gap_id <<<"$row")"
    count="$(jq -r .count <<<"$row")"
    last_ts="$(jq -r .last_ts <<<"$row")"
    last_kind="$(jq -r .last_kind <<<"$row")"
    seen_ts="$(jq -r --arg g "$gap" '.loops[$g].last_ts // ""' <<<"$STATE")"
    filed="$(jq -r --arg g "$gap" '.loops[$g].filed // false' <<<"$STATE")"

    # Re-block only when a NEW bad cycle was observed since the last action —
    # makes the detector immune to the stuck-pr-filer auto-flip back to open.
    [[ "$last_ts" > "$seen_ts" ]] || continue

    log "loop: $gap count=$count last_kind=$last_kind"
    emit no_ship_loop_detected "$(jq -cn --arg g "$gap" --argjson c "$count" \
        --arg k "$last_kind" --argjson n "$THRESHOLD" --arg d "${DRY_RUN:+true}" \
        '{gap_id:$g,count:$c,last_kind:$k,threshold:$n,dry_run:($d=="true")}')"
    if [[ -z "$DRY_RUN" ]]; then
        "$CHUMP_BIN" gap set "$gap" --status blocked \
            --add-note "no-ship-loop-detector (RESILIENT-1573): $count consecutive non-shipping cycles (last=$last_kind); dep-gate: do not re-pick until root cause is fixed" \
            >/dev/null 2>&1 || log "gap set blocked failed for $gap"
    fi
    if [[ "$filed" != "true" ]]; then
        file_gap "RESILIENT: no-ship loop on $gap ($count cycles, last=$last_kind)" \
            "no-ship-loop-detector observed $gap picked $count times with zero verified ships (last kind=$last_kind). Auto-blocked. Diagnose why cycles fail to ship (see ambient cycle_end events) before unblocking."
        filed=true
    fi
    STATE="$(jq -c --arg g "$gap" --arg t "$last_ts" --argjson f "$filed" \
        '.loops[$g] = {last_ts:$t, filed:$f}' <<<"$STATE")"
done <<<"$loops"

# ── (2) systemd crash-loops (user + system scope) ────────────────────────────
if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    for scope in user system; do
        flag=(); [[ "$scope" == user ]] && flag=(--user)
        units="$("$SYSTEMCTL" "${flag[@]}" list-units --type=service --all \
            --plain --no-legend --no-pager "$UNIT_GLOB" 2>/dev/null | awk '{print $1}' || true)"
        [[ -n "$units" ]] || continue
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            n="$("$SYSTEMCTL" "${flag[@]}" show -p NRestarts --value "$unit" 2>/dev/null | head -1)"
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            (( n > CRASH_THRESHOLD )) || continue
            key="$scope:$unit"
            prev="$(jq -r --arg k "$key" '.crash[$k].n // 0' <<<"$STATE")"
            filed="$(jq -r --arg k "$key" '.crash[$k].filed // false' <<<"$STATE")"
            # Re-alarm only when the restart count has grown since last alarm.
            (( n > prev )) || continue
            log "crash-loop: $key NRestarts=$n"
            emit service_crash_loop "$(jq -cn --arg u "$unit" --arg s "$scope" \
                --argjson n "$n" --argjson t "$CRASH_THRESHOLD" \
                '{unit:$u,scope:$s,nrestarts:$n,threshold:$t}')"
            if [[ "$filed" != "true" ]]; then
                file_gap "RESILIENT: systemd service $unit crash-looping ($scope scope, NRestarts=$n)" \
                    "no-ship-loop-detector read NRestarts=$n for $unit ($scope scope) over threshold $CRASH_THRESHOLD. Inspect: systemctl ${flag[*]:-} status $unit; journalctl ${flag[*]:-} -u $unit."
                filed=true
            fi
            STATE="$(jq -c --arg k "$key" --argjson n "$n" --argjson f "$filed" \
                '.crash[$k] = {n:$n, filed:$f}' <<<"$STATE")"
        done <<<"$units"
    done
fi

save_state
exit 0
