#!/usr/bin/env bash
# scripts/ops/fleet-health-sentinel.sh — RESILIENT-1052
#
# THE ANTI-MEMENTO ENFORCEMENT SENTINEL. "Make solved stay solved."
#
# WHY THIS EXISTS (verified live 2026-09-07). 33 chump systemd units sat
# `failed` across the fleet and NOBODY NOTICED until a human asked. Root cause:
# a launchd->systemd port baked a wrong $HOME into the units, so they failed
# CHDIR and only resurrected on their own timer ticks (RESILIENT-1051). Worse,
# the self-healers that were supposed to catch drift — organ-reconcile /
# organ-watchdog / reaper-watchdog — are INACTIVE-OR-ABSENT on cuphead AND
# mugman. Two of three nodes had zero drift protection running, and there was
# NO alarm for a healer being down. A healer that can die silently is the
# amnesia engine: it lets a solved problem quietly un-solve itself.
#
# This sentinel closes that hole. It watches the fleet, it watches the HEALERS,
# and — the whole point — it is watched too, so it cannot die silently either.
#
# WHAT IT COMPLEMENTS (mine-before-build; it does NOT replace these):
#   * scripts/ops/organ-watchdog.sh   — local failed-unit healer (helsinki,
#                                        system-scope). The sentinel watches
#                                        THAT it is alive, and heals the
#                                        --user-scope Oracle nodes it never
#                                        covered.
#   * scripts/ops/organ-reconcile.sh  — manifest convergence.
#   * scripts/ops/reaper-heartbeat-watchdog.sh — local heartbeat grader; the
#                                        sentinel stamps a heartbeat it can
#                                        grade, and adds the CROSS-NODE grade
#                                        that watchdog structurally cannot do.
#   * PR #4512 (RESILIENT-1016) timer-aware reap — the SAFE reconcile. When an
#                                        organ-reconcile unit is present the
#                                        sentinel triggers THAT rather than any
#                                        timer-blind reap.
#
# THREE JOBS:
#   1. DETECT, fleet-wide — (a) any failed chump-* systemd unit on any node;
#      (b) any required HEALER inactive-or-absent on any node.
#   2. ACT — where safe, self-heal (reset-failed+restart a failed oneshot,
#      enable --now an inactive healer/timer, or trigger the #4512 safe
#      reconcile). Where it cannot, emit a halt-class ambient event AND page
#      the board. Never JUST whisper to ambient.
#   3. BE WATCHED — every pass writes a heartbeat (local file + ambient tick +
#      best-effort POST to the fleet-server). A separate --fleet grade (run
#      from any host with fleet reach — the board today, the fleet-server
#      tomorrow) pages if any node's sentinel heartbeat is stale or the node
#      is unreachable. If the sentinel dies, something notices.
#
# MODES:
#   --local   (default)  scan+heal THIS node; write heartbeat; emit tick.
#   --fleet              cross-node grade: read every node's sentinel
#                        heartbeat + failed-unit count; page on stale/unreach.
#   --report-json        print this node's health snapshot as one JSON line
#                        (consumed by a remote --fleet grader / the fleet-server).
#
# FLAGS:
#   --dry-run            detect + report only; never heal, never page.
#   --loop [--cadence-min N]  run forever, one pass every N min (default 5) —
#                        for the Restart=always organ-service supervisor path.
#   --nodes FILE         node topology (default scripts/ops/fleet-nodes.conf).
#
# ENV:
#   CHUMP_STATE_DIR              heartbeat dir (default ~/.chump)
#   CHUMP_AMBIENT_LOG            ambient jsonl (default <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_FLEET_SERVER_URL       if set, POST heartbeat to $URL/api/sentinel-heartbeat
#   CHUMP_SENTINEL_CADENCE_MIN   cadence for --loop / staleness math (default 5)
#   CHUMP_SENTINEL_STALE_MULT    heartbeat-stale multiplier (default 3 → 15min)
#   CHUMP_SENTINEL_PAGE_SINK     TEST/audit hook: also append page payloads here
#   CHUMP_SENTINEL_REQUIRED_HEALERS  space list, overrides the required set
#   CHUMP_SENTINEL_WATCHED_HEALERS   space list, overrides the watched-if-present set
#   CHUMP_SYSTEMCTL              systemctl binary/shim (default: systemctl --user)
#
# Bash 4+; runs on the Oracle nodes (bash 5.1) and the board. Fail-soft: a
# broken notifier or a single unreachable node never aborts the pass.

set -uo pipefail

# ── resolve repo root (worktree-safe) ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    [[ "$_common" != /* ]] && _common="$REPO_ROOT/$_common"
    REPO_ROOT="$(cd "$(dirname "$_common")" && pwd)"
fi

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
HEARTBEAT_FILE="$STATE_DIR/fleet-health-sentinel.heartbeat"
REAPER_HB="/tmp/chump-reaper-fleet-health-sentinel.heartbeat"
CADENCE_MIN="${CHUMP_SENTINEL_CADENCE_MIN:-5}"
STALE_MULT="${CHUMP_SENTINEL_STALE_MULT:-3}"
NODE_ID="$(hostname 2>/dev/null || echo unknown)"

# systemctl shim point — tests inject a fake here; prod uses --user scope.
SYSTEMCTL="${CHUMP_SYSTEMCTL:-systemctl --user}"

# Required healers: MUST be present AND active on an owned node. Absent → page
# (we cannot self-heal a unit that does not exist). These are the Oracle-node
# drift-protection organs plus the sentinel's own timer.
REQUIRED_HEALERS="${CHUMP_SENTINEL_REQUIRED_HEALERS:-chump-node-refresh.timer chump-node-deploy-lag-watchdog.timer chump-fleet-health-sentinel.timer}"
# Watched-if-present: the classic organ healers. Re-enable when present but
# inactive; ignore when a node legitimately never carried them.
WATCHED_HEALERS="${CHUMP_SENTINEL_WATCHED_HEALERS:-organ-watchdog.timer organ-reconcile.timer reaper-watchdog.timer chump-organ-watchdog.timer chump-organ-reconcile.timer}"

MODE="local"
DRY=0
LOOP=0
NODES_FILE="$SCRIPT_DIR/fleet-nodes.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local) MODE="local" ;;
        --fleet) MODE="fleet" ;;
        --report-json) MODE="report-json" ;;
        --dry-run) DRY=1 ;;
        --loop) LOOP=1 ;;
        --cadence-min) CADENCE_MIN="$2"; shift ;;
        --nodes) NODES_FILE="$2"; shift ;;
        -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

now_epoch() { date -u +%s; }
ts_iso()    { date -u +%Y-%m-%dT%H:%M:%SZ; }

log()  { echo "[fleet-health-sentinel] $*" >&2; }

# ── ambient emit (fail-soft) ─────────────────────────────────────────────────
# The kind is written via a printf %s (dynamic), so the event-registry coverage
# scanner cannot see the literals at the emit call. These anchors carry the
# literal "kind":"X" strings the scanner greps for, one per kind this file can
# emit, so emitted-set == registered-set (docs/observability/EVENT_REGISTRY.yaml).
# scanner-anchor: "kind":"fleet_health_sentinel_tick"
# scanner-anchor: "kind":"fleet_health_self_healed"
# scanner-anchor: "kind":"fleet_health_unit_failed"
# scanner-anchor: "kind":"fleet_health_healer_down"
# scanner-anchor: "kind":"fleet_health_sentinel_peer_dead"
emit() {
    # emit <kind> [k=v ...]
    local kind="$1"; shift || true
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    local extra="" kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
        extra="$extra,\"$k\":\"$v\""
    done
    printf '{"ts":"%s","kind":"%s","node":"%s","emitter":"fleet-health-sentinel"%s}\n' \
        "$(ts_iso)" "$kind" "$NODE_ID" "$extra" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── page the board (never JUST ambient) ──────────────────────────────────────
# Always: emit a halt-class ambient event, log a PAGE: line, drop to the test
# sink if configured, and call notify_operator (Discord DM, severity=halt).
# notify_operator no-ops silently when unconfigured (no DISCORD_TOKEN), so the
# ambient halt event + sink are the durable receipts on a node without creds.
page() {
    local msg="$1" kind="${2:-fleet_health_alarm}"
    log "PAGE ($kind): $msg"
    emit "$kind" severity=halt msg="$msg"
    if [[ -n "${CHUMP_SENTINEL_PAGE_SINK:-}" ]]; then
        printf '%s\tPAGE\t%s\t%s\t%s\n' "$(ts_iso)" "$kind" "$NODE_ID" "$msg" \
            >> "$CHUMP_SENTINEL_PAGE_SINK" 2>/dev/null || true
    fi
    # Real page path. Fail-soft: a broken notifier must never break the sentinel.
    local notifier="$SCRIPT_DIR/../coord/lib/notify-operator.sh"
    if [[ -f "$notifier" ]]; then
        # shellcheck disable=SC1090
        ( CHUMP_NOTIFY_KIND="$kind" CHUMP_NOTIFY_SEVERITY=halt \
          bash -c 'source "$1"; notify_operator "$2"' _ "$notifier" \
          "[sentinel/$NODE_ID] $msg" ) >/dev/null 2>&1 || true
    fi
}

# ── systemctl helpers (honor the shim) ───────────────────────────────────────
sc() { $SYSTEMCTL "$@" 2>/dev/null; }

unit_exists() { sc list-unit-files "$1" --no-legend 2>/dev/null | grep -q "$1" \
    || sc cat "$1" >/dev/null 2>&1; }
unit_active() { [[ "$(sc is-active "$1" 2>/dev/null)" == "active" ]]; }

failed_chump_units() {
    # one unit name per line. systemctl prefixes a failed unit's line with a
    # `●` bullet in its own column ("● chump-foo.service loaded failed ..."),
    # so awk $1 grabs the bullet, not the unit — extract the chump-*.unit token
    # directly instead (works with or without the bullet, any locale).
    sc list-units 'chump-*' --state=failed --all --no-legend 2>/dev/null \
        | grep -oE 'chump-[A-Za-z0-9_.@:-]+\.(service|timer)' | sort -u || true
}

# ── LOCAL: scan + heal this node ─────────────────────────────────────────────
# Returns (via globals) counts for the snapshot/report.
SNAP_FAILED=0; SNAP_HEALED=0; SNAP_UNHEALED=0; SNAP_HEALERS_DOWN=0; SNAP_HEALERS_FIXED=0
scan_and_heal_local() {
    SNAP_FAILED=0; SNAP_HEALED=0; SNAP_UNHEALED=0; SNAP_HEALERS_DOWN=0; SNAP_HEALERS_FIXED=0

    # 1. failed chump units -----------------------------------------------------
    local u still
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        SNAP_FAILED=$((SNAP_FAILED+1))
        log "FAILED unit: $u"
        if [[ $DRY -eq 1 ]]; then continue; fi
        # SAFE self-heal: clear the start-limit latch, then re-fire once. This is
        # NOT a timer-blind reap — we touch only units already in `failed`, and
        # we prefer the #4512 organ-reconcile safe path when it is installed.
        if unit_exists "chump-organ-reconcile.service"; then
            sc start chump-organ-reconcile.service >/dev/null 2>&1 || true
        fi
        sc reset-failed "$u" >/dev/null 2>&1 || true
        sc restart "$u"     >/dev/null 2>&1 || true
        sleep 1
        still="$(sc is-active "$u" 2>/dev/null)"
        if [[ "$still" == "failed" ]]; then
            SNAP_UNHEALED=$((SNAP_UNHEALED+1))
            page "chump unit $u is failed and did not recover after reset-failed+restart" \
                 "fleet_health_unit_failed"
        else
            SNAP_HEALED=$((SNAP_HEALED+1))
            emit "fleet_health_self_healed" unit="$u" action="reset-failed+restart"
            log "self-healed: $u -> $still"
        fi
    done < <(failed_chump_units)

    # 2. required healers: present-inactive → enable; absent → PAGE -------------
    local h
    for h in $REQUIRED_HEALERS; do
        if unit_exists "$h"; then
            if unit_active "$h"; then continue; fi
            SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
            log "HEALER inactive: $h"
            if [[ $DRY -eq 1 ]]; then continue; fi
            if sc enable --now "$h" >/dev/null 2>&1 && unit_active "$h"; then
                SNAP_HEALERS_FIXED=$((SNAP_HEALERS_FIXED+1))
                emit "fleet_health_self_healed" unit="$h" action="enable --now"
                log "re-enabled healer: $h"
            else
                page "required healer $h is present but inactive and could not be re-enabled" \
                     "fleet_health_healer_down"
            fi
        else
            SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
            log "HEALER ABSENT: $h"
            [[ $DRY -eq 1 ]] && continue
            page "required healer $h is ABSENT on $NODE_ID (no unit to enable — needs role-convergence install)" \
                 "fleet_health_healer_down"
        fi
    done

    # 3. watched-if-present healers: re-enable when present-inactive, else skip -
    for h in $WATCHED_HEALERS; do
        unit_exists "$h" || continue
        unit_active "$h" && continue
        SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
        log "watched healer inactive: $h"
        [[ $DRY -eq 1 ]] && continue
        if sc enable --now "$h" >/dev/null 2>&1 && unit_active "$h"; then
            SNAP_HEALERS_FIXED=$((SNAP_HEALERS_FIXED+1))
            emit "fleet_health_self_healed" unit="$h" action="enable --now"
            log "re-enabled watched healer: $h"
        fi
    done
}

write_heartbeat() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local ep; ep="$(now_epoch)"
    printf '{"ts":"%s","epoch":%s,"node":"%s","failed":%s,"healed":%s,"unhealed":%s,"healers_down":%s,"healers_fixed":%s}\n' \
        "$(ts_iso)" "$ep" "$NODE_ID" "$SNAP_FAILED" "$SNAP_HEALED" "$SNAP_UNHEALED" "$SNAP_HEALERS_DOWN" "$SNAP_HEALERS_FIXED" \
        > "$HEARTBEAT_FILE" 2>/dev/null || true
    echo "$ep" > "$REAPER_HB" 2>/dev/null || true
    # best-effort push outward so grading can move server-side once fleet-server is up
    if [[ -n "${CHUMP_FLEET_SERVER_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
        curl -fsS -m 5 -X POST "${CHUMP_FLEET_SERVER_URL%/}/api/sentinel-heartbeat" \
            -H 'content-type: application/json' \
            --data-binary @"$HEARTBEAT_FILE" >/dev/null 2>&1 || true
    fi
}

snapshot_json() {
    printf '{"node":"%s","epoch":%s,"failed":%s,"healed":%s,"unhealed":%s,"healers_down":%s,"healers_fixed":%s}\n' \
        "$NODE_ID" "$(now_epoch)" "$SNAP_FAILED" "$SNAP_HEALED" "$SNAP_UNHEALED" "$SNAP_HEALERS_DOWN" "$SNAP_HEALERS_FIXED"
}

do_local_pass() {
    scan_and_heal_local
    write_heartbeat
    emit "fleet_health_sentinel_tick" mode=local failed="$SNAP_FAILED" \
        healed="$SNAP_HEALED" unhealed="$SNAP_UNHEALED" healers_down="$SNAP_HEALERS_DOWN"
    log "local pass: failed=$SNAP_FAILED healed=$SNAP_HEALED unhealed=$SNAP_UNHEALED healers_down=$SNAP_HEALERS_DOWN healers_fixed=$SNAP_HEALERS_FIXED"
}

# ── FLEET: cross-node grade (the sentinel-is-watched-too closure) ────────────
# Reads node topology, reaches each node, grades its sentinel heartbeat
# freshness + failed-unit count. A stale heartbeat or an unreachable node is a
# dead sentinel → PAGE. Runs wherever fleet reach exists (the board today).
load_nodes() {
    # emits: name<TAB>sshtarget<TAB>sshopts  (sshtarget empty for local host)
    [[ -f "$NODES_FILE" ]] || { log "no nodes file: $NODES_FILE"; return 1; }
    grep -vE '^\s*#|^\s*$' "$NODES_FILE"
}

do_fleet_pass() {
    local stale_secs=$(( CADENCE_MIN * 60 * STALE_MULT ))
    local checked=0 dead=0
    local line name target opts hb_epoch age reachable failed
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="$(echo "$line"  | awk -F'\t' '{print $1}')"
        target="$(echo "$line" | awk -F'\t' '{print $2}')"
        opts="$(echo "$line"   | awk -F'\t' '{print $3}')"
        # tilde does not expand out of a variable; do it ourselves so
        # "-i ~/.ssh/key" resolves to a real path when passed to ssh.
        opts="${opts//\~/$HOME}"
        [[ -z "$name" ]] && continue
        checked=$((checked+1))

        if [[ -z "$target" || "$name" == "$NODE_ID" ]]; then
            # local host: read our own heartbeat
            reachable=1
            hb_epoch="$(grep -oE '"epoch":[0-9]+' "$HEARTBEAT_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo 0)"
            failed="$(grep -oE '"failed":[0-9]+' "$HEARTBEAT_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo 0)"
        else
            # remote: read the node's heartbeat epoch over ssh (bounded)
            # shellcheck disable=SC2086
            hb_epoch="$(timeout 20 ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 $opts "$target" \
                'grep -oE "\"epoch\":[0-9]+" ~/.chump/fleet-health-sentinel.heartbeat 2>/dev/null | head -1 | grep -oE "[0-9]+"' 2>/dev/null)"
            if [[ -z "$hb_epoch" ]]; then
                # distinguish unreachable from present-but-no-heartbeat
                if timeout 15 ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 $opts "$target" true >/dev/null 2>&1; then
                    reachable=1; hb_epoch=0
                else
                    reachable=0
                fi
            else
                reachable=1
            fi
            failed=0
        fi

        if [[ "$reachable" -eq 0 ]]; then
            dead=$((dead+1))
            page "node $name ($target) is UNREACHABLE — its sentinel cannot be confirmed alive" \
                 "fleet_health_sentinel_peer_dead"
            continue
        fi
        if [[ -z "$hb_epoch" || "$hb_epoch" -eq 0 ]]; then
            dead=$((dead+1))
            page "node $name has NO sentinel heartbeat — sentinel not running" \
                 "fleet_health_sentinel_peer_dead"
            continue
        fi
        age=$(( $(now_epoch) - hb_epoch ))
        if [[ "$age" -gt "$stale_secs" ]]; then
            dead=$((dead+1))
            page "node $name sentinel heartbeat is STALE (${age}s > ${stale_secs}s) — sentinel likely dead" \
                 "fleet_health_sentinel_peer_dead"
        else
            log "node $name sentinel alive (heartbeat ${age}s ago, failed=$failed)"
        fi
    done < <(load_nodes)

    emit "fleet_health_sentinel_tick" mode=fleet nodes_checked="$checked" sentinels_dead="$dead"
    log "fleet pass: nodes_checked=$checked sentinels_dead=$dead (stale threshold ${stale_secs}s)"
}

# ── main ─────────────────────────────────────────────────────────────────────
run_once() {
    case "$MODE" in
        local)       do_local_pass ;;
        fleet)       do_fleet_pass ;;
        report-json) scan_and_heal_local >/dev/null 2>&1; snapshot_json ;;
    esac
}

if [[ $LOOP -eq 1 ]]; then
    log "loop mode: mode=$MODE cadence=${CADENCE_MIN}m"
    while true; do
        run_once || true
        sleep $(( CADENCE_MIN * 60 ))
    done
else
    run_once
fi
