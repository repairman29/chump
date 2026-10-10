#!/usr/bin/env bash
# offense-ledger.sh — INFRA-3832 chronic-offender ledger, shared by the rc!=0
# branch and the rc==0 unverified_ship path (RESILIENT-1584).
# Needs: REPO_ROOT. Optional: AGENT_ID, CHUMP_SESSION_ID, CHUMP_AMBIENT_LOG.

# offense_bump GAP -> echoes the new consecutive non-ship count.
offense_bump() {
    local gap="$1" dir="$REPO_ROOT/.chump-locks/offense" n=0
    mkdir -p "$dir" 2>/dev/null || true
    [ -f "$dir/${gap}.count" ] && n=$(tr -cd '0-9' < "$dir/${gap}.count" 2>/dev/null || echo 0)
    n=$(( ${n:-0} + 1 ))
    printf '%d\n' "$n" > "$dir/${gap}.count" 2>/dev/null || true
    echo "$n"
}

# offense_clear GAP — a verified ship wipes the ledger.
offense_clear() {
    rm -f "$REPO_ROOT/.chump-locks/offense/${1}.count" 2>/dev/null || true
}

# offense_maybe_block GAP N KIND RC LOGBYTES -> sets status=blocked at threshold.
offense_maybe_block() {
    local gap="$1" n="$2" kind="$3" rc="$4" logb="${5:-0}"
    local thr="${CHUMP_AUTO_BLOCK_THRESHOLD:-3}"
    [ "${CHUMP_AUTO_BLOCK_OFFENDERS:-1}" != "0" ] || return 0
    [ "${n:-0}" -ge "$thr" ] || return 0
    local note="INFRA-3832 auto-block: ${n} consecutive non-ship cycles (last kind=${kind}, rc=${rc}, cycle_log=${logb}B). Worker kept re-picking + looping; blocked to leave the pick pool. Un-block after fixing the spec / decomposing."
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    if CHUMP_REPO="$REPO_ROOT" chump gap set "$gap" --status blocked --add-note "$note" >/dev/null 2>&1; then
        type log >/dev/null 2>&1 && log "INFRA-3832: auto-blocked $gap after ${n} non-ship cycles (kind=${kind})"
        printf '{"event":"ALERT","kind":"gap_auto_blocked","ts":"%s","session":"%s","agent":"%s","gap_id":"%s","offenses":%d,"last_kind":"%s","rc":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CHUMP_SESSION_ID:-fleet}" "${AGENT_ID:-}" "$gap" "$n" "$kind" "$rc" \
            >> "$amb" 2>/dev/null || true
        offense_clear "$gap"
    else
        type log >/dev/null 2>&1 && log "INFRA-3832: WARN could not auto-block $gap (chump gap set failed); cooldown still applied"
    fi
    return 0
}
