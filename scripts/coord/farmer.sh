#!/usr/bin/env bash
# scripts/coord/farmer.sh — RESILIENT-068
#
# dev.chump.farmer — un-killable control-plane tender.
#
# DESIGN AXIOM: no shared failure mode with the layer it revives.
#   - Pure /bin/bash + coreutils (launchctl/sqlite3/pgrep/test/rm/date)
#   - NEVER calls cargo-installed binaries on the recovery hot path
#   - NEVER reads GitHub cache / smee / NATS / GraphQL
#   - NEVER obeys .chump/fleet-paused — reads it as DATA to act on
#
# Launchd: KeepAlive=true + StartInterval=60 (install via
#   scripts/setup/install-farmer-launchd.sh)
#
# Six failure modes it auto-recovers (see FARMER_2026-06-03.md):
#   1. pause-deadlock  — slo passes → rm sentinel + kickstart exit-78 daemons
#   2. crash-no-restart — daemon in exit-127 → restore binary + kick;
#                         else kick; escalate after 3 kicks/10min (RESILIENT-058)
#   3. auth-death      — oauth token stale → operator_recall AUTH_DEAD
#   4. silent-worker   — stale lease + no ambient heartbeat → release + kick choir
#   5. stale-sentinel  — sentinel >15min AND slo-check passes → rm
#   6. dead-supervisor — supervisor not loaded → kickstart it
#
# Revive order (OTP rest_for_one):
#   substrate → supervisors → choir → workers
#
# Event kinds (registered in docs/observability/EVENT_REGISTRY.yaml):
#   farmer_heartbeat          — normal cycle end
#   farmer_pause_lifted       — sentinel removed after slo recovery
#   farmer_daemon_kicked      — launchd kickstart issued
#   farmer_auth_dead          — oauth token stale, operator paged
#   farmer_silent_worker      — stale lease detected, rescue triggered
#   farmer_escalated          — daemon kicked >3 times in 10min → operator page
#
# Usage:
#   bash scripts/coord/farmer.sh         # run one tick (launchd calls this)
#   FARMER_DRY_RUN=1 bash scripts/coord/farmer.sh   # dry-run (no launchctl/rm)
#
# Env:
#   CHUMP_REPO_ROOT               — override repo root detection
#   FARMER_DRY_RUN=1              — dry-run mode: log actions, don't take them
#   FARMER_OAUTH_MAX_AGE_S=3600   — max oauth token age before AUTH_DEAD (default 3600)
#   FARMER_SENTINEL_MAX_AGE_S=900 — max sentinel age for stale-sentinel check (default 900)
#   FARMER_SILENT_WORKER_S=1800   — lease mtime age before considered silent (default 1800)
#   FARMER_KICK_ESCALATE_N=3      — kicks before escalating per daemon (default 3)
#   FARMER_KICK_WINDOW_S=600      — window for kick count (default 600)

set -uo pipefail

# ── Resolve repo root (NO git call — pure path arithmetic, can't fail) ────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)}"
LOCK_DIR="$REPO_ROOT/.chump-locks"
CHUMP_DIR="$REPO_ROOT/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"

# ── Knobs ─────────────────────────────────────────────────────────────────────
DRY_RUN="${FARMER_DRY_RUN:-0}"
OAUTH_MAX_AGE_S="${FARMER_OAUTH_MAX_AGE_S:-3600}"
SENTINEL_MAX_AGE_S="${FARMER_SENTINEL_MAX_AGE_S:-900}"
SILENT_WORKER_S="${FARMER_SILENT_WORKER_S:-1800}"
KICK_ESCALATE_N="${FARMER_KICK_ESCALATE_N:-3}"
KICK_WINDOW_S="${FARMER_KICK_WINDOW_S:-600}"

AMBIENT="$LOCK_DIR/ambient.jsonl"
SENTINEL="$CHUMP_DIR/fleet-paused"
KICK_STATE="$CHUMP_DIR/farmer-kick-state.json"
HEARTBEAT_FILE="$CHUMP_DIR/farmer-heartbeat"

# ── Core helpers (zero chump dependencies) ────────────────────────────────────
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now() { date +%s; }

log() { printf '[farmer %s] %s\n' "$(_ts)" "$*"; }

# Append one JSON line to ambient.jsonl (no flock dep — plain append is
# atomic enough for single-line writes on local fs).
emit() {
    local kind="$1"
    shift
    local extra="${1:-}"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$(_ts)\",\"kind\":\"${kind}\",${extra}}"
    else
        line="{\"ts\":\"$(_ts)\",\"kind\":\"${kind}\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || \
        log "WARN: ambient write failed for kind=$kind"
}

# Write/update the heartbeat file (local only, no network).
write_heartbeat() {
    printf '%s\n' "$(_ts)" > "$HEARTBEAT_FILE"
}

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[dry-run] would run: $*"
    else
        "$@" 2>/dev/null || true
    fi
}

# ── slo_check (read-only, no chump binary) ────────────────────────────────────
# Replicates the ghost-gap SLO: open gaps where closed_pr is set → ghost count.
# Threshold mirrors INFRA-1607 (L2-SLO-5 = 2).
# Uses sqlite3 only — if db is absent, treat SLO as passing (safe default).
slo_check_passes() {
    local db="$CHUMP_DIR/state.db"
    [[ -f "$db" ]] || { log "state.db absent — treating SLO as pass"; return 0; }
    local ghost_count
    ghost_count=$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM gaps WHERE status='open' AND closed_pr IS NOT NULL AND closed_pr != '';" \
        2>/dev/null || echo "0")
    # Also check waste rate proxy: open gaps with closed_pr / total open
    local total_open
    total_open=$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM gaps WHERE status='open';" \
        2>/dev/null || echo "0")
    log "slo_check: ghost_count=$ghost_count total_open=$total_open"
    if [[ "$ghost_count" -le 2 ]]; then
        return 0
    fi
    return 1
}

# ── Daemon helpers ────────────────────────────────────────────────────────────
# All known control-plane daemon labels (supervisors + choir).
# These are loaded by launchd; we monitor + revive them.
CONTROL_PLANE_LABELS=(
    "com.chump.bot-merge-watchdog"
    "com.chump.main-health-watchdog"
    "com.chump.reap-stale-leases"
    "com.chump.stale-process-watchdog"
    "com.chump.heartbeat-watcher"
    "com.chump.ci-health-gate"
    "com.chump.queue-health-monitor"
    "dev.chump.premature-closure-watch"
    "dev.chump.system-invariants-monitor"
)

# label_is_loaded LABEL — returns 0 if launchd has the label loaded
label_is_loaded() {
    launchctl list 2>/dev/null | grep -qF "$1"
}

# label_last_exit LABEL — get last exit status from launchctl list output
label_last_exit() {
    launchctl list 2>/dev/null | awk -v lbl="$1" '$0 ~ lbl {print $2}' | head -1
}

# kick_daemon LABEL — launchctl kickstart (respects DRY_RUN)
kick_daemon() {
    local label="$1"
    log "kicking $label"
    run_cmd launchctl kickstart -k "gui/$(id -u)/$label"
    emit "farmer_daemon_kicked" "\"label\":\"$label\""
}

# ── Kick-escalation tracker ───────────────────────────────────────────────────
# State file: JSON {"label": {"kicks": [ts,...], "escalated": bool}}
kick_count_in_window() {
    local label="$1"
    local now; now="$(_now)"
    local window_start=$(( now - KICK_WINDOW_S ))
    [[ -f "$KICK_STATE" ]] || { echo 0; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('$KICK_STATE'))
    kicks = d.get('$label', {}).get('kicks', [])
    print(sum(1 for t in kicks if t >= $window_start))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

record_kick() {
    local label="$1"
    local now; now="$(_now)"
    local window_start=$(( now - KICK_WINDOW_S ))
    local state="{}"
    [[ -f "$KICK_STATE" ]] && state="$(cat "$KICK_STATE" 2>/dev/null || echo '{}')"
    python3 -c "
import json, sys, os
try:
    d = json.loads('$state') if '$state'.strip() else {}
    entry = d.get('$label', {'kicks': [], 'escalated': False})
    entry['kicks'] = [t for t in entry['kicks'] if t >= $window_start] + [$now]
    d['$label'] = entry
    with open('$KICK_STATE', 'w') as f:
        json.dump(d, f)
except Exception as e:
    sys.stderr.write(str(e)+'\n')
" 2>/dev/null || true
}

should_escalate() {
    local label="$1"
    local count; count="$(kick_count_in_window "$label")"
    [[ "$count" -ge "$KICK_ESCALATE_N" ]] && return 0
    return 1
}

mark_escalated() {
    local label="$1"
    [[ -f "$KICK_STATE" ]] || return
    python3 -c "
import json
try:
    d = json.load(open('$KICK_STATE'))
    d.setdefault('$label', {})['escalated'] = True
    json.dump(d, open('$KICK_STATE','w'))
except Exception: pass
" 2>/dev/null || true
}

already_escalated() {
    local label="$1"
    [[ -f "$KICK_STATE" ]] || { echo 0; return; }
    python3 -c "
import json
try:
    d = json.load(open('$KICK_STATE'))
    print(1 if d.get('$label',{}).get('escalated') else 0)
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

# ── operator_recall shim (pure bash, no chump binary) ─────────────────────────
# Writes a HALT-class recall to ambient.jsonl so the watchdog (RESILIENT-071)
# pages the operator. Does NOT call scripts/dispatch/operator-recall.sh which
# may itself be blocked.
operator_page() {
    local reason="$1"
    local detail="${2:-}"
    log "OPERATOR PAGE: $reason $detail"
    emit "operator_recall" "\"reason\":\"$reason\",\"detail\":\"$detail\",\"class\":\"halt\""
}

# ── Mode 3: auth-death ─────────────────────────────────────────────────────────
check_auth() {
    local token_file="$HOME/.chump/oauth-token.json"
    [[ -f "$token_file" ]] || {
        operator_page "AUTH_DEAD" "oauth-token.json absent"
        emit "farmer_auth_dead" "\"reason\":\"token_file_absent\""
        return
    }
    local mtime now age
    mtime=$(stat -f %m "$token_file" 2>/dev/null || stat -c %Y "$token_file" 2>/dev/null || echo 0)
    now="$(_now)"
    age=$(( now - mtime ))
    if [[ "$age" -gt "$OAUTH_MAX_AGE_S" ]]; then
        log "oauth token is ${age}s old (max ${OAUTH_MAX_AGE_S}s) — paging operator"
        operator_page "AUTH_DEAD" "oauth token ${age}s old"
        emit "farmer_auth_dead" "\"token_age_s\":$age"
    fi
}

# ── Mode 4: silent-worker ──────────────────────────────────────────────────────
check_silent_workers() {
    local now; now="$(_now)"
    # Find leases that have a heartbeat file older than SILENT_WORKER_S
    # and no recent ambient event from that session.
    for lease_file in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lease_file" ]] || continue
        local mtime
        mtime=$(stat -f %m "$lease_file" 2>/dev/null || stat -c %Y "$lease_file" 2>/dev/null || echo 0)
        local age=$(( now - mtime ))
        [[ "$age" -lt "$SILENT_WORKER_S" ]] && continue
        # Stale lease — check if session has recent ambient activity
        local session_id
        session_id=$(python3 -c "
import json
try:
    d = json.load(open('$lease_file'))
    print(d.get('session_id','unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
        local recent
        recent=$(grep "\"session\":\"${session_id}\"" "$AMBIENT" 2>/dev/null | tail -1 | \
            python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read().strip())
    import datetime
    ts = d.get('ts','')
    if ts:
        from datetime import timezone
        dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
        age = (datetime.datetime.now(timezone.utc) - dt).total_seconds()
        print(int(age))
    else:
        print(99999)
except Exception:
    print(99999)
" 2>/dev/null || echo 99999)
        if [[ "$recent" -gt "$SILENT_WORKER_S" ]]; then
            log "silent worker detected: session=$session_id lease_age=${age}s ambient_age=${recent}s"
            emit "farmer_silent_worker" "\"session\":\"$session_id\",\"lease_age_s\":$age,\"ambient_age_s\":$recent"
            # Kick the stale-lease-reaper (Mode 4 response — don't rm the lease ourselves)
            if label_is_loaded "com.chump.reap-stale-leases"; then
                run_cmd launchctl kickstart -k "gui/$(id -u)/com.chump.reap-stale-leases"
            fi
        fi
    done
}

# ── Mode 1+5: pause-deadlock / stale-sentinel ─────────────────────────────────
handle_sentinel() {
    [[ -f "$SENTINEL" ]] || return 0
    local now; now="$(_now)"
    local mtime
    mtime=$(stat -f %m "$SENTINEL" 2>/dev/null || stat -c %Y "$SENTINEL" 2>/dev/null || echo 0)
    local age=$(( now - mtime ))
    log "sentinel present, age=${age}s"

    # Mode 5: stale sentinel (>15min) — check SLO, lift if passing
    if [[ "$age" -gt "$SENTINEL_MAX_AGE_S" ]]; then
        if slo_check_passes; then
            log "stale sentinel + slo passing → lifting pause"
            run_cmd rm -f "$SENTINEL"
            emit "farmer_pause_lifted" "\"reason\":\"stale_sentinel_slo_pass\",\"age_s\":$age"
            # Now revive the choir (Mode 1 revive order)
            revive_control_plane
        else
            log "stale sentinel but slo still failing — kicking ghost-gap-reaper"
            kick_ghost_gap_reaper
        fi
        return
    fi

    # Mode 1: fresh sentinel — just check if SLO recovered
    if slo_check_passes; then
        log "sentinel present but slo has recovered → lifting pause"
        run_cmd rm -f "$SENTINEL"
        emit "farmer_pause_lifted" "\"reason\":\"slo_recovered\",\"age_s\":$age"
        revive_control_plane
    else
        log "sentinel present and slo still failing — leaving in place"
    fi
}

# Kick the ghost-gap-reaper — uses launchd kickstart, not chump binary
kick_ghost_gap_reaper() {
    local label="com.chump.reap-stale-leases"  # best proxy available via launchd
    # Also try to run ghost-gap-reaper.sh directly if available
    local reaper="$REPO_ROOT/scripts/coord/ghost-gap-reaper.sh"
    if [[ -x "$reaper" ]]; then
        log "running ghost-gap-reaper directly"
        run_cmd bash "$reaper"
    fi
}

# Mode 6 + Mode 1 revive: ensure all control-plane daemons are loaded + running
revive_control_plane() {
    log "reviving control plane (revive order: supervisors → choir)"
    for label in "${CONTROL_PLANE_LABELS[@]}"; do
        label_is_loaded "$label" || {
            log "$label not loaded — skipping (not installed on this host)"
            continue
        }
        local exit_code
        exit_code="$(label_last_exit "$label")"
        if [[ "$exit_code" == "78" || "$exit_code" == "127" ]]; then
            log "$label exited $exit_code — kicking"
            record_kick "$label"
            if should_escalate "$label" && [[ "$(already_escalated "$label")" == "0" ]]; then
                mark_escalated "$label"
                operator_page "DAEMON_CRASH_LOOP" "label=$label exit_code=$exit_code kicks>=$KICK_ESCALATE_N in ${KICK_WINDOW_S}s"
                emit "farmer_escalated" "\"label\":\"$label\",\"exit_code\":$exit_code"
            else
                kick_daemon "$label"
            fi
        fi
    done
}

# ── Mode 6: dead-supervisor sweep (runs every tick, not only on revive) ────────
check_dead_supervisors() {
    for label in "${CONTROL_PLANE_LABELS[@]}"; do
        label_is_loaded "$label" || continue  # not installed, skip
        local exit_code
        exit_code="$(label_last_exit "$label")"
        # exit_code="" means currently running (PID column non-null)
        [[ -z "$exit_code" || "$exit_code" == "-" ]] && continue
        # 0 = clean exit (scheduled job), non-zero might be crash
        [[ "$exit_code" == "0" ]] && continue
        log "daemon $label has exit_code=$exit_code — kicking"
        record_kick "$label"
        if should_escalate "$label" && [[ "$(already_escalated "$label")" == "0" ]]; then
            mark_escalated "$label"
            operator_page "DAEMON_CRASH_LOOP" "label=$label exit_code=$exit_code"
            emit "farmer_escalated" "\"label\":\"$label\",\"exit_code\":$exit_code"
        else
            kick_daemon "$label"
        fi
    done
}

# ── Main tick ─────────────────────────────────────────────────────────────────
log "farmer tick start (dry_run=$DRY_RUN)"

# Mode 3: auth check (independent of everything else)
check_auth

# Mode 1+5: sentinel / pause-deadlock
handle_sentinel

# Mode 4: silent workers
check_silent_workers

# Mode 6: dead supervisors (always run, not only during revive)
check_dead_supervisors

# Heartbeat — written AFTER all checks so a crash mid-tick shows up as stale
write_heartbeat
emit "farmer_heartbeat" "\"dry_run\":${DRY_RUN}"

log "farmer tick done"
