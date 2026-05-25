#!/usr/bin/env bash
# scripts/coord/fleet-autopilot.sh — META-090
#
# Single command that runs the full operator playbook as one daemon set.
# Walk-away test: operator runs `chump fleet autopilot start` and walks away;
# PRs drain, gaps refresh, curators stay fed, demo evidence accumulates.
#
# Layers (per META-090 AC#1):
#   (1) PR management daemons (auto-rebase, auto-rearm, pr-pulse, pr-pulse-consumer, transient-retrigger)
#   (2) Oracle refresh cron
#   (3) JIT scheduler
#   (4) Curator sessions (6 launchd plists, CHUMP_SESSION_ID auto-export per INFRA-1880)
#   (5) Master heartbeat (every 5 min, reports daemon-set health)
#
# Composition: invokes chump-fleet-bootstrap.sh (5 base daemons: paramedic, watchdogs)
# FIRST, then installs the autopilot-specific layers on top.
#
# Usage:
#   bash scripts/coord/fleet-autopilot.sh start              # full start
#   bash scripts/coord/fleet-autopilot.sh stop               # graceful stop all
#   bash scripts/coord/fleet-autopilot.sh status [--json]    # one-shot health report
#   bash scripts/coord/fleet-autopilot.sh restart            # stop then start
#   bash scripts/coord/fleet-autopilot.sh heartbeat          # internal: master heartbeat tick
#
# Telemetry kinds:
#   autopilot_started     — start complete (all layers loaded)
#   autopilot_stopped     — stop complete (all daemons unloaded)
#   autopilot_heartbeat   — periodic master tick with daemon-set health summary
#   autopilot_partial     — some layers failed to start (degraded mode)
#
# Bypass: CHUMP_AUTOPILOT_DISABLED=1 prevents `start` (for forensic operator sessions).
#
# Pairs with: scripts/setup/install-fleet-autopilot-launchd.sh (the heartbeat cron).

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
LOG_DIR="$REPO_ROOT/.chump-locks/autopilot-logs"
mkdir -p "$LOG_DIR"

# All autopilot-managed daemons (label → install script).
# REQUIRED_DAEMONS from chump-fleet-bootstrap.sh are loaded FIRST, then these.
AUTOPILOT_LAYERS=(
    # Layer 1: PR management
    # NOTE: pr-auto-rebase + auto-arm-sweeper installers use `dev.chump.*`
    # prefix (legacy); RESILIENT-021 reconciled the registry to match the
    # actual labels each installer writes. Don't "normalize" without updating
    # the installer or the launchctl lookup will silently miss.
    "dev.chump.pr-auto-rebase|scripts/setup/install-pr-auto-rebase-launchd.sh"
    "dev.chump.auto-arm-sweeper|scripts/setup/install-auto-arm-sweeper-launchd.sh"
    "com.chump.pr-pulse-consumer|scripts/setup/install-pr-pulse-consumer-launchd.sh"
    "com.chump.transient-retrigger|scripts/setup/install-transient-retrigger-launchd.sh"
    # Layer 2: Oracle refresh
    "com.chump.oracle-refresh|scripts/setup/install-oracle-refresh-launchd.sh"
    # Layer 3: JIT scheduler
    "com.chump.curator-jit-scheduler|scripts/setup/install-curator-jit-scheduler-launchd.sh"
    # Layer 4: Curator sessions
    # install-curator-launchd.sh manages TWO plists (opus-curator + emergency-fast-path)
    # so we list both labels but share the same installer. The installer is
    # idempotent and skips already-loaded plists, so calling it twice via the
    # autopilot start loop is safe.
    "com.chump.opus-curator|scripts/setup/install-curator-launchd.sh"
    "com.chump.emergency-fast-path|scripts/setup/install-curator-launchd.sh"
    # Layer 5: Master heartbeat (this file's own cron)
    "com.chump.fleet-autopilot|scripts/setup/install-fleet-autopilot-launchd.sh"
    # Substrate (depends on CREDIBLE-076)
    "com.chump.refresh-runner-binary|scripts/setup/install-refresh-runner-binary-launchd.sh"
    # THE FLOOR Phase 1 (INFRA-1987 / META-106): cluster detector
    "com.chump.cluster-detector|scripts/setup/install-cluster-detector-launchd.sh"
    # THE FLOOR Phase 3 (INFRA-1994 / META-106): wedge state machine
    "com.chump.wedge-state-machine|scripts/setup/install-wedge-state-machine-launchd.sh"
    # THE FLOOR Phase 3 / INFRA-2014: live A2A inbox injector
    "com.chump.inbox-injector|scripts/setup/install-inbox-injector-launchd.sh"
    # INFRA-2026: post-push PR integrity watch — auto-reopen stale-base force-close incidents
    "com.chump.post-push-integrity|scripts/setup/install-post-push-integrity-launchd.sh"
)

emit() {
    local kind="$1" extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

is_loaded() {
    local label="$1"
    launchctl list 2>/dev/null | grep -qE "^[0-9-]+\s+[0-9-]+\s+${label}$"
}

cmd_start() {
    if [[ "${CHUMP_AUTOPILOT_DISABLED:-0}" == "1" ]]; then
        log "BYPASS: CHUMP_AUTOPILOT_DISABLED=1; refusing to start"
        return 0
    fi
    log "autopilot start — invoking chump-fleet-bootstrap (5 base daemons)…"
    bash "$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh" 2>&1 | tail -5 || log "WARN: bootstrap returned non-zero"
    log "autopilot start — installing $((${#AUTOPILOT_LAYERS[@]})) autopilot layer(s)…"
    local started=0 skipped=0 failed=0 failures=""
    for entry in "${AUTOPILOT_LAYERS[@]}"; do
        local label="${entry%%|*}"
        local script="${entry##*|}"
        if is_loaded "$label"; then
            log "  ✓ $label (already loaded)"
            skipped=$((skipped+1))
            continue
        fi
        if [[ ! -x "$REPO_ROOT/$script" ]]; then
            log "  ✗ $label (missing $script)"
            failed=$((failed+1))
            failures="$failures $label"
            continue
        fi
        if bash "$REPO_ROOT/$script" >/dev/null 2>&1; then
            log "  ✓ $label"
            started=$((started+1))
        else
            log "  ✗ $label (installer exit non-zero)"
            failed=$((failed+1))
            failures="$failures $label"
        fi
    done
    log "start complete: started=$started skipped=$skipped failed=$failed"
    if (( failed > 0 )); then
        emit autopilot_partial "\"started\":$started,\"skipped\":$skipped,\"failed\":$failed,\"failures\":\"$failures\""
    else
        emit autopilot_started "\"layers\":$((${#AUTOPILOT_LAYERS[@]})),\"started\":$started,\"skipped\":$skipped"
    fi
}

cmd_stop() {
    log "autopilot stop — unloading $((${#AUTOPILOT_LAYERS[@]})) layer(s)…"
    local stopped=0 absent=0
    for entry in "${AUTOPILOT_LAYERS[@]}"; do
        local label="${entry%%|*}"
        local plist="$HOME/Library/LaunchAgents/${label}.plist"
        if [[ -f "$plist" ]]; then
            launchctl unload "$plist" 2>/dev/null && stopped=$((stopped+1)) && log "  ⊘ $label" || log "  ✗ $label (unload failed)"
        else
            absent=$((absent+1))
        fi
    done
    log "stop complete: stopped=$stopped absent=$absent"
    emit autopilot_stopped "\"stopped\":$stopped,\"absent\":$absent"
}

cmd_status() {
    local format="${1:-text}"
    local loaded=0 absent=0 plist_present=0
    local report=()
    for entry in "${AUTOPILOT_LAYERS[@]}"; do
        local label="${entry%%|*}"
        local plist="$HOME/Library/LaunchAgents/${label}.plist"
        local p_ok="no" l_ok="no"
        [[ -f "$plist" ]] && { p_ok="yes"; plist_present=$((plist_present+1)); }
        is_loaded "$label" && { l_ok="yes"; loaded=$((loaded+1)); }
        [[ "$p_ok" == "no" ]] && absent=$((absent+1))
        report+=("$label|plist=$p_ok|loaded=$l_ok")
    done
    # Recent ambient activity (last 5 min, any kind)
    local recent_events
    if [[ -f "$AMBIENT" ]]; then
        recent_events=$(tail -200 "$AMBIENT" 2>/dev/null | grep -cE "$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M", gmtime(time-300))')" || echo 0)
    else
        recent_events=0
    fi
    if [[ "$format" == "json" ]]; then
        printf '{"layers":%d,"loaded":%d,"plist_present":%d,"absent":%d,"recent_ambient_events_5min":%s,"daemons":[' \
            "${#AUTOPILOT_LAYERS[@]}" "$loaded" "$plist_present" "$absent" "$recent_events"
        local sep=""
        for r in "${report[@]}"; do
            local n=${r%%|*}; local rest=${r#*|}
            local p=${rest%%|*}; local l=${rest##*|}
            # p is like "plist=yes" / l is like "loaded=no" — split into key/value
            local p_v="${p##*=}"; local l_v="${l##*=}"
            printf '%s{"label":"%s","plist":"%s","loaded":"%s"}' "$sep" "$n" "$p_v" "$l_v"
            sep=","
        done
        printf ']}\n'
    else
        echo "=== chump fleet autopilot status ==="
        echo "  layers configured: ${#AUTOPILOT_LAYERS[@]}"
        echo "  loaded:            $loaded"
        echo "  plist-present:     $plist_present"
        echo "  absent:            $absent"
        echo "  ambient events (last 5min): $recent_events"
        echo
        for r in "${report[@]}"; do echo "  $r"; done
    fi
}

cmd_heartbeat() {
    # Internal: called by the launchd cron every 5 min.
    local loaded=0
    for entry in "${AUTOPILOT_LAYERS[@]}"; do
        local label="${entry%%|*}"
        is_loaded "$label" && loaded=$((loaded+1))
    done
    local total=${#AUTOPILOT_LAYERS[@]}
    emit autopilot_heartbeat "\"loaded\":$loaded,\"total\":$total"
    # If <80% loaded, alert via STDERR (launchd captures stderr to log)
    if (( loaded * 5 < total * 4 )); then
        echo "[autopilot] DEGRADED: only $loaded/$total daemons loaded" >&2
        emit autopilot_partial "\"loaded\":$loaded,\"total\":$total,\"reason\":\"heartbeat_degraded\""
    fi
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

main() {
    local cmd="${1:-status}"
    case "$cmd" in
        start)     cmd_start ;;
        stop)      cmd_stop ;;
        status)    cmd_status "${2:-text}" ;;
        restart)   cmd_restart ;;
        heartbeat) cmd_heartbeat ;;
        -h|--help|help)
            sed -n '2,35p' "$0" | sed 's/^# \?//'
            ;;
        *) echo "Unknown command: $cmd. Use start|stop|status|restart|heartbeat" >&2; exit 2 ;;
    esac
}

main "$@"
