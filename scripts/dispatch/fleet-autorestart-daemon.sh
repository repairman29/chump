#!/usr/bin/env bash
# fleet-autorestart-daemon.sh — INFRA-611: auto-restart daemon for the fleet.
#
# Watches ambient.jsonl and polls trigger conditions; restarts the fleet
# automatically. Spawned by run-fleet.sh outside tmux, alongside the
# orphan-reaper sentinel (INFRA-602). Exits when the fleet tmux session
# disappears.
#
# Trigger conditions (all gated by CHUMP_FLEET_AUTO_RESTART != 0):
#
#   (a) VERSION SKEW — running fleet's worker.sh diverges from main on
#       coord-affecting paths (INFRA-609) AND no in-flight PR covers the
#       gap that introduced the change.
#
#   (b) WEDGE CLUSTER — ≥ CHUMP_FLEET_WEDGE_RESTART_THRESHOLD (default 3)
#       fleet_wedge events within the last 30 min.
#
#   (c) STALE UPTIME — fleet has been running for > 24 h (stale-clone risk).
#
#   (d) AUTH STORM — CHUMP_AUTH_STORM_RESTART_THRESHOLD (default 3)
#       fleet_auth_storm events in ambient.jsonl (INFRA-623).
#
# Each trigger emits kind=fleet_auto_restart_decision to ambient.jsonl with
# reasoning, then waits 60 s for operator override (send SIGTERM or write
# kind=fleet_auto_restart_cancel to ambient.jsonl), then calls fleet-restart.sh.
#
# Env knobs:
#   CHUMP_FLEET_AUTO_RESTART              0 = disabled; default 1
#   CHUMP_AUTH_STORM_RESTART_THRESHOLD    default 3
#   CHUMP_FLEET_WEDGE_RESTART_THRESHOLD   default 3
#   CHUMP_FLEET_WEDGE_WINDOW_SECS         default 1800 (30 min)
#   CHUMP_FLEET_UPTIME_LIMIT_SECS         default 86400 (24 h)
#   CHUMP_FLEET_AUTO_RESTART_GRACE_SECS   default 60
#   CHUMP_FLEET_SKEW_CHECK_INTERVAL_SECS  default 300 (5 min)
#   FLEET_SESSION                         default chump-fleet
#   FLEET_START_EPOCH                     Unix epoch from run-fleet.sh launch
#   CHUMP_AMBIENT_LOG                     path to ambient.jsonl

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"
FLEET_START_EPOCH="${FLEET_START_EPOCH:-0}"

_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_lock_dir="$(dirname "$_amb")"
_restart_script="$REPO_ROOT/scripts/dispatch/fleet-restart.sh"
_skew_script="$REPO_ROOT/scripts/dev/fleet-version-skew-detect.sh"

CHUMP_FLEET_AUTO_RESTART="${CHUMP_FLEET_AUTO_RESTART:-1}"
_auth_storm_threshold="${CHUMP_AUTH_STORM_RESTART_THRESHOLD:-3}"
_wedge_threshold="${CHUMP_FLEET_WEDGE_RESTART_THRESHOLD:-3}"
_wedge_window="${CHUMP_FLEET_WEDGE_WINDOW_SECS:-1800}"
_uptime_limit="${CHUMP_FLEET_UPTIME_LIMIT_SECS:-86400}"
_grace_secs="${CHUMP_FLEET_AUTO_RESTART_GRACE_SECS:-60}"
_skew_check_interval="${CHUMP_FLEET_SKEW_CHECK_INTERVAL_SECS:-300}"
_poll_interval=10

# State files (survive subshell boundaries)
_wedge_times_file="$_lock_dir/fleet-autorestart-wedge-times.txt"
_restart_lock="$_lock_dir/fleet-autorestart.lock"
_processed_lines_file="$_lock_dir/fleet-autorestart-lines.txt"

_log()  { printf '[fleet-autorestart-daemon] %s\n' "$*"; }
_fleet_alive() { tmux has-session -t "$FLEET_SESSION" 2>/dev/null; }

_emit() {
    local kind="$1" msg="$2"
    mkdir -p "$_lock_dir" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","message":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$msg" \
        >> "$_amb" 2>/dev/null || true
}

# ── Wedge-time tracking ────────────────────────────────────────────────────────

_record_wedge_now() {
    date +%s >> "$_wedge_times_file" 2>/dev/null || true
}

_wedge_count_recent() {
    [[ -f "$_wedge_times_file" ]] || { echo 0; return; }
    local now cutoff count=0 line
    now=$(date +%s)
    cutoff=$((now - _wedge_window))
    local tmp
    tmp=$(mktemp 2>/dev/null || echo "$_wedge_times_file.tmp")
    : > "$tmp"
    while IFS= read -r line; do
        [[ -n "$line" && "$line" -gt "$cutoff" ]] || continue
        (( count++ )) || true
        printf '%s\n' "$line" >> "$tmp"
    done < "$_wedge_times_file" 2>/dev/null || true
    mv "$tmp" "$_wedge_times_file" 2>/dev/null || true
    echo "$count"
}

# ── In-flight PR check for version-skew trigger ───────────────────────────────
# Returns 0 if it is safe to restart (no open PR covers the skew-gap).
# Returns 1 if an in-flight PR is found — skip restart to avoid interrupting it.
_no_inflight_pr_for_skew() {
    # Determine which commits on origin/main changed worker.sh since HEAD
    local local_sha main_sha affected_gaps="" pr_count
    local_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
    main_sha="$(git rev-parse origin/main 2>/dev/null || echo "")"
    [[ -z "$local_sha" || -z "$main_sha" || "$local_sha" = "$main_sha" ]] && return 0

    # Extract gap IDs (e.g., INFRA-NNN) from commit messages
    affected_gaps="$(git log --oneline "${local_sha}..${main_sha}" \
        -- scripts/dispatch/worker.sh 2>/dev/null \
        | grep -oE '(INFRA|FLEET|META)-[0-9]+' | sort -u || true)"

    [[ -z "$affected_gaps" ]] && return 0  # no gap IDs — safe to restart

    if ! command -v gh >/dev/null 2>&1; then
        _log "gh not available — skipping in-flight PR check"
        return 0
    fi

    # Check if any affected gap has an open PR
    while IFS= read -r gap_id; do
        [[ -z "$gap_id" ]] && continue
        # Fleet branches follow naming: chump/<lowercased-gap-id>-*
        local branch_prefix
        branch_prefix="chump/$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')"
        pr_count="$(gh pr list --state open --json number \
            --search "head:${branch_prefix}" 2>/dev/null | \
            grep -c '"number"' 2>/dev/null || echo 0)"
        if [[ "$pr_count" -gt 0 ]]; then
            _log "in-flight PR for ${gap_id} — skipping version-skew restart"
            return 1
        fi
    done <<< "$affected_gaps"

    return 0
}

# ── Grace period + restart ────────────────────────────────────────────────────
# Takes trigger name and reason string.  Emits decision event, waits _grace_secs,
# checks for cancel, then calls fleet-restart.sh.
_restart_with_grace() {
    local trigger="$1" reason="$2"

    if [[ "$CHUMP_FLEET_AUTO_RESTART" = "0" ]]; then
        _log "auto-restart disabled (CHUMP_FLEET_AUTO_RESTART=0) — ignoring trigger=$trigger"
        _emit "fleet_auto_restart_decision" \
            "trigger=${trigger} disabled=CHUMP_FLEET_AUTO_RESTART=0 reason=${reason}"
        return 0
    fi

    # Mutual-exclusion: bail if another restart is already in progress
    if [[ -f "$_restart_lock" ]]; then
        local lock_pid lock_age
        lock_pid="$(cat "$_restart_lock" 2>/dev/null || echo "")"
        if kill -0 "$lock_pid" 2>/dev/null; then
            _log "restart already in progress (pid=$lock_pid) — skipping trigger=$trigger"
            return 0
        fi
        rm -f "$_restart_lock"
    fi
    printf '%s' "$$" > "$_restart_lock"

    _emit "fleet_auto_restart_decision" \
        "trigger=${trigger} reason=${reason} grace_secs=${_grace_secs} daemon_pid=$$ override_hint=send SIGTERM to $$ or emit fleet_auto_restart_cancel"
    _log "trigger=$trigger — $reason"
    _log "grace period: ${_grace_secs}s — send SIGTERM to $$ or emit kind=fleet_auto_restart_cancel to cancel"

    local _cancelled=0
    _grace_over() { _cancelled=0; }   # no-op; we poll below
    trap '_cancelled=1; _log "restart cancelled via SIGTERM"' TERM INT

    local elapsed=0
    while [[ $elapsed -lt $_grace_secs ]]; do
        sleep 5 || true
        elapsed=$((elapsed + 5))

        # Operator cancel via ambient event
        if tail -5 "$_amb" 2>/dev/null | grep -q '"kind":"fleet_auto_restart_cancel"'; then
            _cancelled=1
            _log "restart cancelled via fleet_auto_restart_cancel event"
            break
        fi

        # Fleet disappeared — nothing to restart
        if ! _fleet_alive; then
            _cancelled=1
            _log "fleet session gone during grace period — skipping restart"
            break
        fi
    done

    trap - TERM INT
    rm -f "$_restart_lock"

    if [[ "$_cancelled" -eq 1 ]]; then
        return 0
    fi

    _log "grace elapsed — restarting fleet (trigger=$trigger)"
    _emit "fleet_auto_restart" "trigger=${trigger} restarting now"

    FLEET_SESSION="$FLEET_SESSION" \
    FLEET_START_EPOCH="$FLEET_START_EPOCH" \
    CHUMP_AMBIENT_LOG="$_amb" \
    REPO_ROOT="$REPO_ROOT" \
    "$_restart_script" --fleet-start-epoch "$FLEET_START_EPOCH" &
}

# ── Periodic checks (version skew + uptime) ───────────────────────────────────
_last_periodic_check=0

_run_periodic_checks() {
    local now
    now=$(date +%s)
    [[ $((now - _last_periodic_check)) -lt $_skew_check_interval ]] && return
    _last_periodic_check="$now"

    # Trigger (c): stale uptime > 24 h
    if [[ "$FLEET_START_EPOCH" -gt 0 ]]; then
        local uptime=$(( now - FLEET_START_EPOCH ))
        if [[ "$uptime" -gt "$_uptime_limit" ]]; then
            _log "uptime=${uptime}s exceeds ${_uptime_limit}s — triggering stale-uptime restart"
            _restart_with_grace "uptime" "fleet_uptime=${uptime}s limit=${_uptime_limit}s" &
            return
        fi
    fi

    # Trigger (a): version skew on coord-affecting paths
    if [[ -x "$_skew_script" ]]; then
        if ! "$_skew_script" --quiet --no-emit 2>/dev/null; then
            # Skew detected (exit 1)
            if _no_inflight_pr_for_skew; then
                _log "coord-affecting version skew detected — triggering skew restart"
                _restart_with_grace "version_skew" \
                    "worker.sh behind origin/main on coord-affecting paths (INFRA-609)" &
            fi
        fi
    fi
}

# ── Main event loop ────────────────────────────────────────────────────────────

# State
_auth_storm_count=0
_last_processed_line=0

# Brief wait for ambient.jsonl to be created by the first worker cycle
_waited=0
while [[ ! -f "$_amb" ]] && _fleet_alive; do
    sleep 2
    (( _waited += 2 )) || true
    [[ $_waited -ge 60 ]] && break
done

mkdir -p "$_lock_dir" 2>/dev/null || true
: > "$_wedge_times_file" 2>/dev/null || true

_log "started — session=$FLEET_SESSION auth_storm_threshold=$_auth_storm_threshold wedge_threshold=$_wedge_threshold uptime_limit=${_uptime_limit}s auto_restart=${CHUMP_FLEET_AUTO_RESTART}"

while _fleet_alive; do
    sleep "$_poll_interval" || true
    _fleet_alive || break

    # ── Process new lines from ambient.jsonl ─────────────────────────────────
    if [[ -f "$_amb" ]]; then
        local_total=$(wc -l < "$_amb" 2>/dev/null | tr -d ' ' || echo 0)
        if [[ "$local_total" -gt "$_last_processed_line" ]]; then
            skip_lines=$(( _last_processed_line + 1 ))
            while IFS= read -r _line; do
                # ── Trigger (d): auth storm ──────────────────────────────────
                # INFRA-1658: case-match dodges printf|grep -q pipefail race.
                # `_line` is one JSON record; substring match is sufficient and
                # avoids the grep-q-early-closes-stdin → printf-SIGPIPE pipeline.
                if [[ "$_line" == *'"kind":"fleet_auth_storm"'* ]]; then
                    (( _auth_storm_count++ )) || true
                    _log "fleet_auth_storm event #${_auth_storm_count}/${_auth_storm_threshold}"
                    if [[ "$_auth_storm_count" -ge "$_auth_storm_threshold" ]]; then
                        _log "auth-storm threshold reached — triggering fleet restart with credential refresh"
                        _auth_storm_count=0
                        (
                            FLEET_SESSION="$FLEET_SESSION" \
                            FLEET_START_EPOCH="$FLEET_START_EPOCH" \
                            CHUMP_AMBIENT_LOG="$_amb" \
                            REPO_ROOT="$REPO_ROOT" \
                            _restart_with_grace "auth_storm" \
                                "auth_storm_threshold=${_auth_storm_threshold} reached"
                            # auth storm uses --refresh-auth
                            [[ -f "$_restart_lock" ]] || \
                            "$_restart_script" --refresh-auth \
                                --fleet-start-epoch "$FLEET_START_EPOCH"
                        ) &
                    fi
                fi

                # ── Trigger (b): wedge cluster ───────────────────────────────
                # INFRA-1658: case-match dodges printf|grep -q pipefail race.
                if [[ "$_line" == *'"kind":"fleet_wedge"'* ]]; then
                    _record_wedge_now
                    local wcount
                    wcount="$(_wedge_count_recent)"
                    _log "fleet_wedge event — ${wcount}/${_wedge_threshold} in last ${_wedge_window}s window"
                    if [[ "$wcount" -ge "$_wedge_threshold" ]]; then
                        _log "wedge threshold reached — triggering wedge restart"
                        : > "$_wedge_times_file"  # reset after trigger
                        _restart_with_grace "wedge_cluster" \
                            "fleet_wedge_count=${wcount} in last ${_wedge_window}s" &
                    fi
                fi

            done < <(tail -n +"$skip_lines" "$_amb" 2>/dev/null || true)
            _last_processed_line="$local_total"
        fi
    fi

    # ── Periodic checks (uptime + version skew) ──────────────────────────────
    _run_periodic_checks
done

_log "fleet session '$FLEET_SESSION' gone — exiting"
rm -f "$_restart_lock" "$_wedge_times_file" "$_processed_lines_file" 2>/dev/null || true
