#!/usr/bin/env bash
# scripts/ops/peer-deadman.sh — RESILIENT-1901
#
# Off-node deadman for the hub. Runs on a node that is NOT the hub (slim) and
# probes the hub over tailscale ping + ssh + the :7070 health endpoint. The hub
# is "up" if ANY layer answers; it is dark only when all three fail. After
# CHUMP_PEER_DEADMAN_PAGE_AFTER_S (default 600) of continuous failure it emits
# kind=node_unreachable and pages once through the quiet gate; nothing more
# until recovery, when it emits kind=node_reachable once. While the hub is dark
# it also runs the twice-daily digest from this node (labelled with the
# producing node) so the operator keeps getting the report.
#
# If this node's own tailnet is down the probe is blind: failures are not
# counted and the tick says observer_tailnet=down.
#
# Test hooks: CHUMP_PEER_DEADMAN_{HUB,STATE_DIR,NOW,TS_BIN,SSH_BIN,CURL_BIN,
# NOTIFY_BIN,DIGEST_BIN,DIGEST_HOURS_UTC,PAGE_AFTER_S}, CHUMP_AMBIENT_LOG.
#
# Rust-First-Bypass: thin probe glue over tailscale/ssh/curl, no canonical-state mutation beyond its own state dir

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
HUB="${CHUMP_PEER_DEADMAN_HUB:-closetjunky}"
STATE_DIR="${CHUMP_PEER_DEADMAN_STATE_DIR:-$REPO_ROOT/.chump-locks/peer-deadman-state}"
PAGE_AFTER_S="${CHUMP_PEER_DEADMAN_PAGE_AFTER_S:-600}"
PORT="${CHUMP_PEER_DEADMAN_PORT:-7070}"
TS_BIN="${CHUMP_PEER_DEADMAN_TS_BIN:-tailscale}"
SSH_BIN="${CHUMP_PEER_DEADMAN_SSH_BIN:-ssh}"
CURL_BIN="${CHUMP_PEER_DEADMAN_CURL_BIN:-curl}"
NOTIFY_BIN="${CHUMP_PEER_DEADMAN_NOTIFY_BIN:-}"
DIGEST_BIN="${CHUMP_PEER_DEADMAN_DIGEST_BIN:-$REPO_ROOT/scripts/dispatch/digest-beat.sh}"
DIGEST_HOURS_UTC="${CHUMP_PEER_DEADMAN_DIGEST_HOURS_UTC:-16 01}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
NOW="${CHUMP_PEER_DEADMAN_NOW:-$(date -u +%s)}"
SELF="$(hostname -s 2>/dev/null || echo unknown)"

mkdir -p "$STATE_DIR" "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
FAIL_FILE="$STATE_DIR/$HUB.first_fail"
PAGED_FILE="$STATE_DIR/$HUB.paged"

emit() {  # kind k=v ...
    local kind="$1"; shift
    local line="{\"ts\":\"$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)\",\"kind\":\"$kind\",\"emitter\":\"peer-deadman\""
    local kv
    for kv in "$@"; do
        line+=",\"${kv%%=*}\":\"${kv#*=}\""
    done
    printf '%s}\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

page() {
    local msg="$1"
    if [[ -n "$NOTIFY_BIN" ]]; then
        "$NOTIFY_BIN" "$msg" || true
    else
        # shellcheck source=/dev/null
        ( export CHUMP_NOTIFY_KIND=node_unreachable
          source "$REPO_ROOT/scripts/coord/lib/notify-operator.sh" && notify_operator "$msg" ) || true
    fi
}

# Observer self-check: an unreachable tailnet on THIS node makes every probe fail.
observer=up
if ! "$TS_BIN" status >/dev/null 2>&1; then observer=down; fi

ts_ok=0 ssh_ok=0 http_ok=0
if [[ "$observer" == up ]]; then
    timeout 10 "$TS_BIN" ping -c 1 --timeout 5s "$HUB" >/dev/null 2>&1 && ts_ok=1
    timeout 15 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=8 "$HUB" true >/dev/null 2>&1 && ssh_ok=1
    timeout 10 "$CURL_BIN" -sf -m 8 "http://$HUB:$PORT/health" >/dev/null 2>&1 && http_ok=1
fi
probes="ping=$ts_ok,ssh=$ssh_ok,http=$http_ok"

if [[ "$observer" == down ]]; then
    # scanner-anchor: "kind":"peer_deadman_tick"
    emit peer_deadman_tick "hub=$HUB" "observer_tailnet=down" "hub_state=unknown" "probes=$probes"
    exit 0
fi

if (( ts_ok || ssh_ok || http_ok )); then
    if [[ -f "$PAGED_FILE" ]]; then
        down_s=$(( NOW - $(cat "$FAIL_FILE" 2>/dev/null || echo "$NOW") ))
        # scanner-anchor: "kind":"node_reachable"
        emit node_reachable "peer=$HUB" "down_seconds=$down_s" "probes=$probes"
    fi
    rm -f "$FAIL_FILE" "$PAGED_FILE"
    emit peer_deadman_tick "hub=$HUB" "observer_tailnet=up" "hub_state=up" "probes=$probes"
    exit 0
fi

[[ -f "$FAIL_FILE" ]] || printf '%s' "$NOW" > "$FAIL_FILE"
first_fail="$(cat "$FAIL_FILE" 2>/dev/null || echo "$NOW")"
down_s=$(( NOW - first_fail ))

if (( down_s >= PAGE_AFTER_S )); then
    hub_state=dark
    if [[ ! -f "$PAGED_FILE" ]]; then
        : > "$PAGED_FILE"
        # scanner-anchor: "kind":"node_unreachable"
        emit node_unreachable "peer=$HUB" "tailnet_ip=n/a" "consecutive_misses=$(( down_s / 300 ))" "dry_run=0" "down_seconds=$down_s" "observer=$SELF" "probes=$probes"
        page "HUB DARK: $HUB failed ping+ssh+:$PORT/health for ${down_s}s (observed from $SELF). No further pages until it recovers."
    fi
    # Chief report fallback: run the digest from this node in each digest hour, once.
    hour="$(date -u -d "@$NOW" +%H)"; day="$(date -u -d "@$NOW" +%Y%m%d)"
    for h in $DIGEST_HOURS_UTC; do
        marker="$STATE_DIR/digest-$day-$h"
        if [[ "$hour" == "$h" && ! -f "$marker" ]]; then
            : > "$marker"
            CHUMP_DIGEST_FALLBACK_REASON="hub $HUB dark ${down_s}s" "$DIGEST_BIN" || true
        fi
    done
else
    hub_state=suspect
fi
emit peer_deadman_tick "hub=$HUB" "observer_tailnet=up" "hub_state=$hub_state" "probes=$probes"
exit 0
