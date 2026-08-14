#!/usr/bin/env bash
# scripts/ops/organ-watchdog.sh — INFRA-3595, self-deploy loop INFRA-3598
#
# WHY THIS EXISTS. Operator directive: the board must NOT hand-restart ATC
# organs (no helicopter parenting). Today none self-heals: chump-sla-scorecard
# .service failed on 2026-08-11 with nothing to bring it back. The systemd
# failure mode here is specifically start-limit-hit — a oneshot unit fired by
# a timer that fails a few times in a row trips systemd's default
# StartLimitBurst, and the unit sits `failed (Result: start-limit-hit)`
# forever: every subsequent timer fire is silently refused until something
# runs `systemctl reset-failed <unit>`. This watchdog is that something.
#
# INFRA-3598: INFRA-3593's merge->deploy path was false-done. node-refresh-
# chump.sh calls `install-helsinki-atc.sh --auto` to reinstall changed
# chump-*.service/.timer files, but node-refresh-chump.sh runs as a systemd
# --user timer (unprivileged) — --auto always hit the "not root, can't write
# /etc/systemd/system" branch and silently no-op'd. Merged unit-file fixes
# (e.g. the INFRA-3595 scorecard fix) never reached the live unit. This
# watchdog already runs as root on a 5-minute cadence (see
# chump-organ-watchdog.service), so it is the first place in the whole chain
# that can actually perform the privileged reinstall. Every cycle now also:
#   0. (opt-in, CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH=1) fast-forwards
#      CHUMP_REPO_ROOT to origin/main so the tracked unit files it reconciles
#      against are never stale (AC 5).
#   0.5. calls `install-helsinki-atc.sh --auto`, which diffs tracked
#      scripts/dispatch/chump-*.service|.timer against what's live and
#      reinstalls + restarts anything changed, emitting
#      kind=organ_units_deployed (AC 1, 3, 7).
#
# Algorithm, every cycle:
#   1. List every chump-*.service unit systemd knows about.
#   2. For each one whose ActiveState=failed: `systemctl reset-failed <unit>`
#      then `systemctl restart <unit>` (oneshots) — clears the start-limit
#      latch and re-fires the unit immediately rather than waiting for the
#      next timer tick.
#   3. Do the same for chump-*.timer units that are enabled but inactive
#      (a timer can itself be disabled by a failed daemon-reload elsewhere).
#   4. Emit kind=organ_self_healed per unit healed (observable proof of
#      self-heal, no human step) and kind=organ_watchdog_tick every run
#      (heartbeat, mirrors main-health-watchdog's success-path emit) so a
#      dead watchdog is itself visible via the standard reaper-heartbeat
#      pattern.
#
# Usage:
#   scripts/ops/organ-watchdog.sh              # scan + heal, real systemctl
#   scripts/ops/organ-watchdog.sh --dry-run     # report only, no restart
#
# Test hooks (used by scripts/ci/test-organ-watchdog.sh):
#   CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN   — path to a stubbed `systemctl`
#   CHUMP_ORGAN_WATCHDOG_GIT_BIN         — path to a stubbed `git`
#   CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT   — override for install-helsinki-atc.sh
#   CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH   — 1 = fast-forward CHUMP_REPO_ROOT to
#                                           origin/main first (default 0; the
#                                           production unit sets this, tests
#                                           and dev boxes leave it off so a
#                                           real WIP checkout is never reset)
#   CHUMP_AMBIENT_LOG                    — override ambient.jsonl path
#
# Exit codes:
#   0  normal (whether or not any organ needed healing)
#   1  systemctl unavailable (non-Linux dev box, or not installed) — quiet
#      no-op, this is expected on a macOS operator laptop
#   2  internal failure (reset-failed/restart itself failed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SYSTEMCTL_BIN="${CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN:-systemctl}"
GIT_BIN="${CHUMP_ORGAN_WATCHDOG_GIT_BIN:-git}"
DEPLOY_SCRIPT="${CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT:-$REPO_ROOT/scripts/setup/install-helsinki-atc.sh}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
    echo "[organ-watchdog] systemctl unavailable ($SYSTEMCTL_BIN not found) — no-op (expected off the helsinki node)"
    exit 1
fi

# ── 0. keep the clone current with origin/main (INFRA-3598, opt-in) ────────
# CHUMP_REPO_ROOT is a dedicated deploy mirror with no operator WIP (same
# assumption node-refresh-chump.sh makes about its own mirror) — safe to
# fast-forward hard. Off by default so a real dev/test checkout is never
# touched; the production chump-organ-watchdog.service unit opts in.
# scanner-anchor: "kind":"organ_clone_refreshed"
# scanner-anchor: "kind":"organ_clone_refresh_failed"
if [[ "${CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH:-0}" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[organ-watchdog] (dry-run) would fetch + fast-forward $REPO_ROOT to origin/main"
    elif [[ ! -e "$REPO_ROOT/.git" ]]; then
        echo "[organ-watchdog] WARN: $REPO_ROOT is not a git checkout; skipping clone refresh" >&2
    elif ! "$GIT_BIN" -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null; then
        echo "[organ-watchdog] WARN: git fetch failed (offline?); using local clone state" >&2
        emit organ_clone_refresh_failed "\"reason\":\"fetch_failed\""
    else
        prev_sha="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
        main_sha="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse --short=12 origin/main 2>/dev/null || echo "$prev_sha")"
        if [[ "$prev_sha" != "$main_sha" ]]; then
            if "$GIT_BIN" -C "$REPO_ROOT" reset --hard origin/main >/dev/null 2>&1; then
                echo "[organ-watchdog] clone refreshed: $prev_sha -> $main_sha"
                emit organ_clone_refreshed "\"prev_sha\":\"$prev_sha\",\"new_sha\":\"$main_sha\""
            else
                echo "[organ-watchdog] WARN: git reset --hard origin/main failed" >&2
                emit organ_clone_refresh_failed "\"reason\":\"reset_failed\""
            fi
        fi
    fi
fi

# ── 0.5. reconcile + reinstall changed chump-* organ units (INFRA-3598) ────
# node-refresh-chump.sh already calls install-helsinki-atc.sh --auto every
# cycle, but it runs unprivileged (systemd --user), so that call always
# no-ops on reason=not_root — a merged unit-file change never reaches
# /etc/systemd/system. This watchdog runs as root (chump-organ-watchdog.service),
# so its call is the one that actually succeeds. install-helsinki-atc.sh
# --auto diffs tracked units against what's live and emits its own
# kind=organ_units_deployed/organ_units_deploy_skipped — this is the board's
# verifiable proof the merge->deploy loop is real (AC 1, 3, 7).
if [[ "$DRY_RUN" == "1" ]]; then
    echo "[organ-watchdog] (dry-run) would run: $DEPLOY_SCRIPT --auto"
elif [[ -x "$DEPLOY_SCRIPT" ]]; then
    NODE_AMBIENT="$AMBIENT_LOG" "$DEPLOY_SCRIPT" --auto \
        || echo "[organ-watchdog] WARN: $DEPLOY_SCRIPT --auto exited non-zero (non-fatal)" >&2
else
    echo "[organ-watchdog] WARN: deploy script not found/executable: $DEPLOY_SCRIPT" >&2
fi

healed=0
scan_fail=0

# ── 1. Failed chump-*.service units ─────────────────────────────────────────
FAILED_SERVICES="$("$SYSTEMCTL_BIN" list-units --all --type=service --state=failed --plain --no-legend 'chump-*.service' 2>/dev/null | awk '{print $1}')"

if [[ -n "$FAILED_SERVICES" ]]; then
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        echo "[organ-watchdog] FAILED: $unit"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[organ-watchdog]   (dry-run) would reset-failed + restart $unit"
            continue
        fi
        if ! "$SYSTEMCTL_BIN" reset-failed "$unit" 2>&1; then
            echo "[organ-watchdog]   ERROR: reset-failed $unit failed" >&2
            # scanner-anchor: "kind":"organ_self_heal_failed"  (INFRA-3595;
            # fires when reset-failed/restart itself errors — a genuinely
            # broken organ, not just a start-limit latch)
            emit organ_self_heal_failed "\"unit\":\"$unit\",\"step\":\"reset-failed\""
            scan_fail=1
            continue
        fi
        if ! "$SYSTEMCTL_BIN" restart "$unit" 2>&1; then
            echo "[organ-watchdog]   ERROR: restart $unit failed" >&2
            emit organ_self_heal_failed "\"unit\":\"$unit\",\"step\":\"restart\""
            scan_fail=1
            continue
        fi
        echo "[organ-watchdog]   healed $unit"
        # scanner-anchor: "kind":"organ_self_healed"  (INFRA-3595; fires when
        # the watchdog resets + restarts a failed chump-* organ with no
        # human step — the self-heal proof the board polls for)
        emit organ_self_healed "\"unit\":\"$unit\",\"action\":\"reset-failed+restart\""
        healed=$((healed + 1))
    done <<< "$FAILED_SERVICES"
fi

# ── 2. Enabled-but-inactive chump-*.timer units ─────────────────────────────
ALL_TIMERS="$("$SYSTEMCTL_BIN" list-unit-files --type=timer --plain --no-legend 'chump-*.timer' 2>/dev/null | awk '$2=="enabled"{print $1}')"

if [[ -n "$ALL_TIMERS" ]]; then
    while IFS= read -r timer; do
        [[ -z "$timer" ]] && continue
        if "$SYSTEMCTL_BIN" is-active --quiet "$timer" 2>/dev/null; then
            continue
        fi
        echo "[organ-watchdog] INACTIVE (but enabled): $timer"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[organ-watchdog]   (dry-run) would start $timer"
            continue
        fi
        if ! "$SYSTEMCTL_BIN" start "$timer" 2>&1; then
            echo "[organ-watchdog]   ERROR: start $timer failed" >&2
            emit organ_self_heal_failed "\"unit\":\"$timer\",\"step\":\"start-timer\""
            scan_fail=1
            continue
        fi
        echo "[organ-watchdog]   healed $timer"
        emit organ_self_healed "\"unit\":\"$timer\",\"action\":\"start-timer\""
        healed=$((healed + 1))
    done <<< "$ALL_TIMERS"
fi

# ── 3. Gap-starter worker liveness (RESILIENT-324) ──────────────────────────
# 2026-08-14 incident: chump-worker@1/@2.service sat SIGTERM-stopped +
# UnitFileState=disabled for 2.5h — no alarm fired because nothing checks
# worker liveness independent of the AUTONOMY_LEVEL kill switch (RESILIENT-321
# only pages when the kill switch itself is 0; a provision/refresh path can
# disable the worker UNITS directly without ever touching AUTONOMY_LEVEL, and
# that went completely unobserved). Only runs when the chump-worker@.service
# template is actually installed on this host — a dev/laptop node with no
# worker template must not get a permanent false alarm.
WORKER_HALT_STATE="$(dirname "$AMBIENT_LOG")/worker-halt-since.ts"
if "$SYSTEMCTL_BIN" list-unit-files --no-legend 'chump-worker@.service' 2>/dev/null | grep -q .; then
    WORKER_IDS="${CHUMP_WORKER_HALT_IDS:-1 2}"
    WORKER_HALT_MIN_SECS="${CHUMP_WORKER_HALT_MIN_SECS:-1800}"
    RECALL_SCRIPT="${CHUMP_ORGAN_WATCHDOG_RECALL_SCRIPT:-$REPO_ROOT/scripts/dispatch/operator-recall.sh}"

    any_worker_active=0
    for _wid in $WORKER_IDS; do
        if "$SYSTEMCTL_BIN" is-active --quiet "chump-worker@${_wid}.service" 2>/dev/null; then
            any_worker_active=1
            break
        fi
    done

    if [[ "$any_worker_active" == "1" ]]; then
        rm -f "$WORKER_HALT_STATE" 2>/dev/null || true
    else
        _now_epoch="$(date +%s)"
        if [[ -f "$WORKER_HALT_STATE" ]]; then
            _since_epoch="$(cat "$WORKER_HALT_STATE" 2>/dev/null || echo "$_now_epoch")"
            [[ "$_since_epoch" =~ ^[0-9]+$ ]] || _since_epoch="$_now_epoch"
        else
            _since_epoch="$_now_epoch"
            [[ "$DRY_RUN" == "1" ]] || echo "$_now_epoch" > "$WORKER_HALT_STATE" 2>/dev/null || true
        fi
        _halt_age=$(( _now_epoch - _since_epoch ))
        echo "[organ-watchdog] WORKER_HALT: 0 active chump-worker@{${WORKER_IDS// /,}}.service for ~${_halt_age}s"
        # scanner-anchor: "kind":"worker_liveness_zero"  (RESILIENT-324; fires
        # every cycle no gap-starter worker unit is active — the board's
        # verifiable proof of how long production has been silently down)
        emit worker_liveness_zero "\"worker_ids\":\"${WORKER_IDS}\",\"halt_age_s\":${_halt_age}"
        if (( _halt_age >= WORKER_HALT_MIN_SECS )); then
            if [[ "$DRY_RUN" == "1" ]]; then
                echo "[organ-watchdog]   (dry-run) would page operator: WORKER_HALT"
            elif [[ -x "$RECALL_SCRIPT" ]]; then
                _halt_mins=$(( _halt_age / 60 ))
                CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$RECALL_SCRIPT" --condition WORKER_HALT \
                    --reason "0 active chump-worker@{${WORKER_IDS// /,}}.service for ~${_halt_mins}m (>= $((WORKER_HALT_MIN_SECS / 60))m threshold); gap-starter workers are down, no new gaps are being claimed" \
                    >/dev/null 2>&1 || echo "[organ-watchdog]   WARN: operator-recall.sh WORKER_HALT call failed" >&2
            fi
        fi
    fi
fi

# Heartbeat — always emit so a dead watchdog is itself observable (paired
# with scripts/ops/reaper-heartbeat-watchdog.sh's cadence-grading pattern).
# scanner-anchor: "kind":"organ_watchdog_tick"  (INFRA-3595; emitted every
# cycle, success or no-op — proof the watchdog itself is alive)
emit organ_watchdog_tick "\"healed\":$healed,\"dry_run\":$DRY_RUN"

echo "[organ-watchdog] cycle complete: healed=$healed dry_run=$DRY_RUN"

[[ "$scan_fail" == "1" ]] && exit 2
exit 0
