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
#   (4) Curator sessions — 6 named tmux windows in chump-curators session (META-122)
#   (5) Master heartbeat (every 5 min, reports daemon-set health + respawns dead curators)
#
# Composition: invokes chump-fleet-bootstrap.sh (5 base daemons: paramedic, watchdogs)
# FIRST, then installs the autopilot-specific layers on top.
#
# Usage:
#   bash scripts/coord/fleet-autopilot.sh start              # full start (launchd + 6 curator sessions)
#   bash scripts/coord/fleet-autopilot.sh stop               # graceful stop all
#   bash scripts/coord/fleet-autopilot.sh status [--json]    # one-shot health report
#   bash scripts/coord/fleet-autopilot.sh restart            # stop then start
#   bash scripts/coord/fleet-autopilot.sh heartbeat          # internal: master heartbeat tick
#
# Telemetry kinds:
#   autopilot_started          — start complete (all layers loaded)
#   autopilot_stopped          — stop complete (all daemons unloaded)
#   autopilot_heartbeat        — periodic master tick with daemon-set health summary
#   autopilot_partial          — some layers failed to start (degraded mode)
#   curator_session_launched   — a curator tmux window was created (META-122)
#   curator_session_respawned  — a dead curator window was recreated by heartbeat (META-122)
#   curator_sessions_stopped   — all curator tmux windows killed (META-122)
#
# Bypass: CHUMP_AUTOPILOT_DISABLED=1 prevents `start` (for forensic operator sessions).
# Bypass: CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH=1 skips the 6 curator session spawning.
#
# Pairs with: scripts/setup/install-fleet-autopilot-launchd.sh (the heartbeat cron).

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
LOG_DIR="$REPO_ROOT/.chump-locks/autopilot-logs"
mkdir -p "$LOG_DIR"

# ── META-122: Curator session config ──────────────────────────────────────
# 6 named curator roles. Each maps to a loop script (if present) + a
# CHUMP_SESSION_ID that the JIT scheduler addresses via broadcast.sh.
# Session name format: curator-opus-<role>-<YYYY-MM-DD> (date fixed at
# launch time, matches JIT scheduler's extract_done_curator pattern).
CURATOR_TMUX_SESSION="${CHUMP_CURATOR_TMUX_SESSION:-chump-curators}"
CURATOR_SESSION_FILE="$REPO_ROOT/.chump-locks/curator-sessions.json"
# Tick cadence: how often each curator loop runs inside its tmux window.
CURATOR_TICK_INTERVAL_S="${CHUMP_CURATOR_TICK_INTERVAL_S:-300}"
# 6 curator roles (must match OPERATOR_PLAYBOOK §1 hierarchy).
# Format: <role>|<loop-script-relative-to-REPO_ROOT>
# shepherd/target have no loop script yet (INFRA-1917 filed); they use
# a minimal heartbeat-only loop until those scripts land.
CURATOR_ROLES=(
    "shepherd|scripts/coord/opus-shepherd-triage.sh"
    "target|"
    "handoff|scripts/coord/handoff-loop.sh"
    "ci-audit|scripts/coord/ci-audit-loop.sh"
    "decompose|scripts/coord/decompose-loop.sh"
    "md-links|scripts/coord/md-links-loop.sh"
)

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
    # META-109 Phase 1: wizard-daemon — autonomous DRIVE primitive (default-OFF)
    # NOTE: this entry loads the launchd plist but the daemon stays INERT until
    # CHUMP_WIZARD_DAEMON_ENABLED=1 is set. The installer default is ENABLED=0.
    # Validate Sprint 1-3 floor primitives before flipping the enable bit.
    "com.chump.wizard-daemon|scripts/setup/install-wizard-daemon-launchd.sh"
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

# ── META-122: Curator session helpers ─────────────────────────────────────

# Build today's session ID for a given role (matches JIT scheduler pattern).
curator_session_id() {
    local role="$1"
    local date_str
    date_str="$(date +%Y-%m-%d)"
    printf 'curator-opus-%s-%s' "$role" "$date_str"
}

# Return the tmux window index for a role in CURATOR_TMUX_SESSION, or "".
curator_tmux_window() {
    local role="$1"
    tmux list-windows -t "$CURATOR_TMUX_SESSION" -F "#{window_index}:#{window_name}" 2>/dev/null \
        | awk -F: -v r="$role" '$2 == r {print $1; exit}'
}

# Build the per-role loop command that runs inside each tmux window.
# - If a loop script exists: calls `<script> tick` every CURATOR_TICK_INTERVAL_S.
# - If no loop script: minimal heartbeat-only loop (for roles not yet productized).
curator_loop_cmd() {
    local role="$1"
    local loop_script="$2"
    local sid
    sid="$(curator_session_id "$role")"
    local log_file="$LOG_DIR/curator-${role}.log"

    if [[ -n "$loop_script" && -x "$REPO_ROOT/$loop_script" ]]; then
        # Productized role: run tick then heartbeat on each cycle.
        printf 'export CHUMP_SESSION_ID=%s REPO_ROOT=%s; while true; do %s/%s tick 2>&1 | tee -a %s; %s/%s heartbeat 2>>%s; sleep %s; done' \
            "$sid" "$REPO_ROOT" \
            "$REPO_ROOT" "$loop_script" "$log_file" \
            "$REPO_ROOT" "$loop_script" "$log_file" \
            "$CURATOR_TICK_INTERVAL_S"
    else
        # Stub role (shepherd/target — no loop script yet): emit ambient heartbeat on cadence.
        # Build the command string without nested printf format confusion.
        local stub_cmd
        # shellcheck disable=SC2016  # variables intentionally deferred to spawned shell
        stub_cmd='export CHUMP_SESSION_ID='"$sid"' REPO_ROOT='"$REPO_ROOT"' AMBIENT='"$AMBIENT"' CURATOR_ROLE='"$role"' LOG_FILE='"$log_file"' INTERVAL='"$CURATOR_TICK_INTERVAL_S"
        stub_cmd+=$'; while true; do ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); printf '"'"'{"ts":"%s","kind":"curator_heartbeat","role":"%s","session":"%s"}\n'"'"' "$ts" "$CURATOR_ROLE" "$CHUMP_SESSION_ID" >> "$AMBIENT" 2>/dev/null || true; echo "[$CURATOR_ROLE] tick $ts" >> "$LOG_FILE" 2>&1; sleep "$INTERVAL"; done'
        printf '%s' "$stub_cmd"
    fi
}

# Spawn a single curator tmux window. Idempotent: no-op if window exists.
# Returns 0 on success (new or existing), 1 on failure.
curator_spawn_one() {
    local role="$1"
    local loop_script="$2"
    local existing
    existing="$(curator_tmux_window "$role")"
    if [[ -n "$existing" ]]; then
        log "  curator-opus-$role: window $existing already present (skipping)"
        return 0
    fi
    local cmd
    cmd="$(curator_loop_cmd "$role" "$loop_script")"
    # Create the tmux session on first curator, add windows for the rest.
    if ! tmux has-session -t "$CURATOR_TMUX_SESSION" 2>/dev/null; then
        tmux new-session -d -s "$CURATOR_TMUX_SESSION" -n "$role" -c "$REPO_ROOT" \
            "/bin/bash -lc '$cmd'" 2>/dev/null || {
            log "  ✗ curator-opus-$role: tmux new-session failed"
            return 1
        }
    else
        tmux new-window -t "$CURATOR_TMUX_SESSION" -n "$role" -c "$REPO_ROOT" \
            "/bin/bash -lc '$cmd'" 2>/dev/null || {
            log "  ✗ curator-opus-$role: tmux new-window failed"
            return 1
        }
    fi
    local sid
    sid="$(curator_session_id "$role")"
    log "  ✓ curator-opus-$role (session=$sid)"
    # scanner-anchor: "kind":"curator_session_launched"
    emit curator_session_launched "\"role\":\"$role\",\"session_id\":\"$sid\",\"loop_script\":\"${loop_script:-none}\""
    return 0
}

# Launch all 6 curator sessions. Respects CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH.
cmd_launch_curators() {
    if [[ "${CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH:-0}" == "1" ]]; then
        log "curator launch: CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH=1 — skipping (operator managing manually)"
        return 0
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        log "WARN: tmux not found — curator sessions cannot be launched; install tmux to enable META-122"
        return 1
    fi
    log "curator launch — spawning up to ${#CURATOR_ROLES[@]} curator sessions in tmux:$CURATOR_TMUX_SESSION …"
    local launched=0 skipped=0 failed=0
    local sessions_json="{"
    local sep=""
    for entry in "${CURATOR_ROLES[@]}"; do
        local role="${entry%%|*}"
        local loop_script="${entry##*|}"
        if curator_spawn_one "$role" "$loop_script"; then
            if [[ -n "$(curator_tmux_window "$role")" ]]; then
                launched=$((launched+1))
                local sid
                sid="$(curator_session_id "$role")"
                sessions_json="${sessions_json}${sep}\"$role\":{\"session_id\":\"$sid\",\"launched_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
                sep=","
            else
                skipped=$((skipped+1))
            fi
        else
            failed=$((failed+1))
        fi
    done
    sessions_json="${sessions_json}}"
    # Write the session registry for heartbeat re-launch checks.
    printf '%s\n' "$sessions_json" > "$CURATOR_SESSION_FILE" 2>/dev/null || true
    log "curator launch complete: launched=$launched skipped=$skipped failed=$failed"
    log "  attach: tmux attach -t $CURATOR_TMUX_SESSION"
    return $(( failed > 0 ? 1 : 0 ))
}

# Gracefully stop all curator tmux windows + kill the tmux session.
cmd_stop_curators() {
    if ! tmux has-session -t "$CURATOR_TMUX_SESSION" 2>/dev/null; then
        log "curator stop: tmux session $CURATOR_TMUX_SESSION not found (already stopped)"
        return 0
    fi
    log "curator stop — killing tmux session $CURATOR_TMUX_SESSION …"
    tmux kill-session -t "$CURATOR_TMUX_SESSION" 2>/dev/null || true
    rm -f "$CURATOR_SESSION_FILE" 2>/dev/null || true
    # scanner-anchor: "kind":"curator_sessions_stopped"
    emit curator_sessions_stopped "\"tmux_session\":\"$CURATOR_TMUX_SESSION\""
    log "  curator sessions stopped"
}

# Check each curator role; respawn any whose tmux window is gone.
# Called by cmd_heartbeat every 5 min. Emits kind=curator_session_respawned.
curator_check_and_respawn() {
    if [[ "${CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH:-0}" == "1" ]]; then
        return 0
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        return 0
    fi
    if ! tmux has-session -t "$CURATOR_TMUX_SESSION" 2>/dev/null; then
        # Whole session gone — re-launch all.
        log "curator heartbeat: tmux session $CURATOR_TMUX_SESSION missing — re-launching all"
        cmd_launch_curators
        return
    fi
    for entry in "${CURATOR_ROLES[@]}"; do
        local role="${entry%%|*}"
        local loop_script="${entry##*|}"
        local existing
        existing="$(curator_tmux_window "$role")"
        if [[ -z "$existing" ]]; then
            local sid
            sid="$(curator_session_id "$role")"
            log "curator heartbeat: $role window missing — respawning"
            if curator_spawn_one "$role" "$loop_script"; then
                # scanner-anchor: "kind":"curator_session_respawned"
                emit curator_session_respawned "\"role\":\"$role\",\"session_id\":\"$sid\""
            fi
        fi
    done
}

# Add 6 curator-session lines to status output.
curator_status_lines() {
    local format="${1:-text}"
    local alive=0 absent=0
    local tmux_ok="no"
    tmux has-session -t "$CURATOR_TMUX_SESSION" 2>/dev/null && tmux_ok="yes"
    local curator_report=()
    for entry in "${CURATOR_ROLES[@]}"; do
        local role="${entry%%|*}"
        local sid
        sid="$(curator_session_id "$role")"
        local window_idx
        window_idx="$(curator_tmux_window "$role")"
        local state
        if [[ -n "$window_idx" ]]; then
            state="alive"
            alive=$((alive+1))
        else
            state="absent"
            absent=$((absent+1))
        fi
        curator_report+=("curator-opus-$role|session=$sid|tmux_window=${window_idx:-none}|state=$state")
    done
    if [[ "$format" == "json" ]]; then
        printf ',"curator_tmux_session":"%s","curator_session_alive":%d,"curator_session_absent":%d,"curators":[' \
            "$CURATOR_TMUX_SESSION" "$alive" "$absent"
        local sep=""
        for r in "${curator_report[@]}"; do
            local name="${r%%|*}"
            # Extract fields
            local sess window st
            sess="$(printf '%s' "$r" | awk -F'|' '{print $2}' | cut -d= -f2)"
            window="$(printf '%s' "$r" | awk -F'|' '{print $3}' | cut -d= -f2)"
            st="$(printf '%s' "$r" | awk -F'|' '{print $4}' | cut -d= -f2)"
            printf '%s{"name":"%s","session":"%s","tmux_window":"%s","state":"%s"}' \
                "$sep" "$name" "$sess" "$window" "$st"
            sep=","
        done
        printf ']'
    else
        echo
        echo "  --- curator sessions (META-122) ---"
        echo "  tmux session: $CURATOR_TMUX_SESSION (present=$tmux_ok)"
        echo "  alive: $alive  absent: $absent"
        for r in "${curator_report[@]}"; do echo "  $r"; done
        echo "  attach: tmux attach -t $CURATOR_TMUX_SESSION"
    fi
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
    # META-122: spawn 6 curator Claude sessions after launchd layers are up.
    cmd_launch_curators || log "WARN: curator session launch had failures (check tmux $CURATOR_TMUX_SESSION)"
}

cmd_stop() {
    # META-122: stop curator sessions first so they don't keep emitting events.
    cmd_stop_curators
    log "autopilot stop — unloading $((${#AUTOPILOT_LAYERS[@]})) layer(s)…"
    local stopped=0 absent=0
    for entry in "${AUTOPILOT_LAYERS[@]}"; do
        local label="${entry%%|*}"
        local plist="$HOME/Library/LaunchAgents/${label}.plist"
        if [[ -f "$plist" ]]; then
            # shellcheck disable=SC2015  # pre-existing; A&&B||C intentional here (unload best-effort)
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
        printf ']'
        # META-122: append curator session status.
        curator_status_lines "json"
        printf '}\n'
    else
        echo "=== chump fleet autopilot status ==="
        echo "  layers configured: ${#AUTOPILOT_LAYERS[@]}"
        echo "  loaded:            $loaded"
        echo "  plist-present:     $plist_present"
        echo "  absent:            $absent"
        echo "  ambient events (last 5min): $recent_events"
        echo
        for r in "${report[@]}"; do echo "  $r"; done
        # META-122: append 6 curator-session lines.
        curator_status_lines "text"
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
    # META-122: count live curator windows for heartbeat telemetry.
    local curators_alive=0
    for entry in "${CURATOR_ROLES[@]}"; do
        local role="${entry%%|*}"
        [[ -n "$(curator_tmux_window "$role")" ]] && curators_alive=$((curators_alive+1))
    done
    local curators_total=${#CURATOR_ROLES[@]}
    # scanner-anchor: "kind":"autopilot_heartbeat"
    emit autopilot_heartbeat "\"loaded\":$loaded,\"total\":$total,\"curators_alive\":$curators_alive,\"curators_total\":$curators_total"
    # If <80% launchd daemons loaded, alert via STDERR (launchd captures stderr to log)
    if (( loaded * 5 < total * 4 )); then
        echo "[autopilot] DEGRADED: only $loaded/$total daemons loaded" >&2
        emit autopilot_partial "\"loaded\":$loaded,\"total\":$total,\"reason\":\"heartbeat_degraded\""
    fi
    # META-122: respawn any dead curator windows.
    curator_check_and_respawn
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
