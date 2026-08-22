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
#   5. (opt-in, CHUMP_ORGAN_WATCHDOG_BINARY_HEAL=1 — INFRA-3651, PEER-HEAL-04)
#      detect a vanished/stale release binary (no target/release/chump, or
#      its build sha older than origin/main HEAD) and trigger a rebuild via
#      node-refresh-chump.sh, emitting kind=organ_binary_healed; separately,
#      detect the binary-refresh organ itself (chump-node-refresh.service —
#      a systemd --user unit, RESILIENT-200, invisible to section 1's
#      system-scope scan) sitting failed, and revive it: systemd --user
#      reset-failed+restart, falling back to a direct process-path re-run of
#      the refresh wrapper if the --user instance can't be reached.
#
# Usage:
#   scripts/ops/organ-watchdog.sh              # scan + heal, real systemctl
#   scripts/ops/organ-watchdog.sh --dry-run     # report only, no restart
#
# Test hooks (used by scripts/ci/test-organ-watchdog.sh):
#   CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN   — path to a stubbed `systemctl`
#   CHUMP_ORGAN_WATCHDOG_GIT_BIN         — path to a stubbed `git`
#   CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT   — override for install-helsinki-atc.sh
#   CHUMP_ORGAN_WATCHDOG_RECONCILE_SCRIPT — RESILIENT-347: override for
#                                           organ-reconcile.sh, called directly
#                                           every cycle (step 0.6, see below)
#   CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH   — 1 = fast-forward CHUMP_REPO_ROOT to
#                                           origin/main first (default 0; the
#                                           production unit sets this, tests
#                                           and dev boxes leave it off so a
#                                           real WIP checkout is never reset)
#   CHUMP_ORGAN_RECONCILE_BACKOFF_DIR    — RESILIENT-347: shared with
#                                           organ-reconcile.sh; a unit with a
#                                           backoff file here (or its .timer
#                                           counterpart) is SKIPPED by section
#                                           1's failed-service heal instead of
#                                           being resurrected every cycle
#   CHUMP_AMBIENT_LOG                    — override ambient.jsonl path
#   CHUMP_ORGAN_WATCHDOG_BINARY_HEAL     — INFRA-3651: 1 = enable section 5
#                                           (binary + binary-refresh-organ
#                                           heal). Default 0 — off in tests
#                                           and dev boxes so a checkout with
#                                           no target/release/chump doesn't
#                                           trigger a real cargo build; the
#                                           production unit sets this.
#   CHUMP_ORGAN_WATCHDOG_NODE_REFRESH_SCRIPT — override for
#                                           node-refresh-chump.sh (section 5)
#   CHUMP_ORGAN_WATCHDOG_USER_SYSTEMCTL_BIN  — override for the `systemctl
#                                           --user` caller (section 5b);
#                                           defaults to
#                                           CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN
#   CHUMP_BINARY_REFRESH_UNIT            — unit name for the binary-refresh
#                                           organ (default
#                                           chump-node-refresh.service)
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

# RESILIENT-347: share organ-reconcile.sh's backoff registry. Without this,
# section 1 below (blind reset-failed+restart of ANY failed chump-*.service)
# resurrects a unit that organ-reconcile just deliberately disabled + backed
# off after a verify failure — recreating the exact "re-installs the failing
# unit every cycle" churn RESILIENT-347 exists to end, just through the
# watchdog's door instead of the installer's.
BACKOFF_DIR="${CHUMP_ORGAN_RECONCILE_BACKOFF_DIR:-$REPO_ROOT/.chump-locks/organ-backoff}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# RESILIENT-347: is `unit` currently cooling down in organ-reconcile.sh's
# backoff registry? Backoff is recorded against the MANIFEST unit, which for
# oneshot organs is usually the .timer (e.g. chump-integrator.timer), while
# this function is called with the *.service name systemd reports as failed
# (e.g. chump-integrator.service) — so also check the .timer counterpart.
organ_watchdog_in_backoff() {  # unit
    local unit="$1"
    [[ -f "$BACKOFF_DIR/${unit}.json" ]] && return 0
    if [[ "$unit" == *.service ]]; then
        [[ -f "$BACKOFF_DIR/${unit%.service}.timer.json" ]] && return 0
    fi
    return 1
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

# ── 0.6. run organ-reconcile.sh directly (RESILIENT-347 step 3) ────────────
# install-helsinki-atc.sh --auto (step 0.5 above) already calls
# organ-reconcile.sh --apply itself as its LAST step (RESILIENT-305 /
# RESILIENT-347's "don't let one failed unit abort the auto-deploy before
# organ-reconcile runs" fix), but that path is coupled to the FULL roster
# install succeeding far enough to reach it (unit-file copy, host-rewrite,
# daemon-reload — any of which can legitimately fail or be skipped, e.g.
# `systemctl daemon-reload` failing exits 0 under --auto WITHOUT ever
# reaching the reconcile call). This watchdog is the fleet's own periodic
# heal cadence (5 min), so it is the right place to call the
# per-node-applicable reconcile (role/requires-gated, verify+backoff —
# RESILIENT-347 steps 1-2, already shipped) DIRECTLY and unconditionally,
# closing the loop described in RESILIENT-347's AC 3: "THEN wire
# organ-watchdog to run it". Safe now specifically BECAUSE steps 1-2 landed
# first — a structurally-broken organ (missing binary/role/deps) is skipped
# as not-applicable or backed off after one failed verify, instead of being
# re-installed and re-failing every single cycle (the pre-347 CJ incident:
# integrator/sla-scorecard/backlog-sync-writer/farmer).
RECONCILE_SCRIPT="${CHUMP_ORGAN_WATCHDOG_RECONCILE_SCRIPT:-$REPO_ROOT/scripts/ops/organ-reconcile.sh}"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "[organ-watchdog] (dry-run) would run: $RECONCILE_SCRIPT --apply"
elif [[ -x "$RECONCILE_SCRIPT" ]]; then
    NODE_AMBIENT="$AMBIENT_LOG" "$RECONCILE_SCRIPT" --apply \
        || echo "[organ-watchdog] WARN: $RECONCILE_SCRIPT --apply exited non-zero (non-fatal)" >&2
else
    echo "[organ-watchdog] WARN: reconcile script not found/executable: $RECONCILE_SCRIPT" >&2
fi

healed=0
scan_fail=0

# ── 1. Failed chump-*.service units ─────────────────────────────────────────
FAILED_SERVICES="$("$SYSTEMCTL_BIN" list-units --all --type=service --state=failed --plain --no-legend 'chump-*.service' 2>/dev/null | awk '{print $1}')"

if [[ -n "$FAILED_SERVICES" ]]; then
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        if organ_watchdog_in_backoff "$unit"; then
            echo "[organ-watchdog] SKIP (backed off by organ-reconcile): $unit"
            # scanner-anchor: "kind":"organ_watchdog_backoff_skip"  (RESILIENT-347;
            # fires when a failed chump-*.service is currently cooling down in
            # organ-reconcile's backoff registry — the watchdog defers to that
            # curated decision instead of blindly resurrecting the unit every
            # cycle, which is the churn RESILIENT-347 exists to end)
            emit organ_watchdog_backoff_skip "\"unit\":\"$unit\""
            continue
        fi
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

# ── 4. Spinning-worker detection & heal (RESILIENT-332) ─────────────────────
# 2026-08-15 incident: worker 2 emitted worker_stuck reason=preflight_fail 108x
# in 15min — it kept re-picking two stale-open gaps that failed pre-pick
# preflight, doing zero work, while looking perfectly healthy to the
# heartbeat-based fleet-worker-watchdog (a spinning worker updates its
# heartbeat every cycle — the silent-worker detector is blind to it). The OS
# emitted the worker_stuck signal 108x and NOTHING consumed it. This section
# is the safety net: it detects a worker spinning on preflight_fail from the
# ambient stream and auto-heals it — restart the worker unit + clear the
# offending stale claim so the picker advances past it. Layers A+B in
# worker.sh/_pick_and_claim_gap.py make the spin structurally impossible at
# the root; this is defence-in-depth for a worker running older code or an
# edge case the picker can't see.
#
# Only runs when the chump-worker@.service template is installed (same guard
# as section 3 — a dev/laptop node has no worker units to restart).
# Tunables: CHUMP_WORKER_SPIN_THRESHOLD (default 20 worker_stuck in the
# window), CHUMP_WORKER_SPIN_WINDOW_S (default 600), CHUMP_WORKER_SPIN_IDS
# (default "1 2"), CHUMP_WORKER_SPIN_HEAL_COOLDOWN_S (min gap between heals of
# the same worker, default = window) so a heal isn't re-fired every tick while
# stale events age out of the window.
LOCKS_DIR="$(dirname "$AMBIENT_LOG")"
if "$SYSTEMCTL_BIN" list-unit-files --no-legend 'chump-worker@.service' 2>/dev/null | grep -q .; then
    SPIN_THRESHOLD="${CHUMP_WORKER_SPIN_THRESHOLD:-20}"
    SPIN_WINDOW_S="${CHUMP_WORKER_SPIN_WINDOW_S:-600}"
    SPIN_IDS="${CHUMP_WORKER_SPIN_IDS:-1 2}"
    SPIN_HEAL_COOLDOWN_S="${CHUMP_WORKER_SPIN_HEAL_COOLDOWN_S:-$SPIN_WINDOW_S}"

    # Count worker_stuck (reason=preflight_fail) per agent within the window,
    # and report the single most-repeated offending gap per spinning agent.
    # Emits one line per spinning agent: "<agent_id> <count> <gap_id>".
    SPIN_REPORT="$(
        CHUMP_SPIN_WINDOW_S="$SPIN_WINDOW_S" \
        CHUMP_SPIN_THRESHOLD="$SPIN_THRESHOLD" \
        AMBIENT_LOG="$AMBIENT_LOG" \
        python3 - <<'PY' 2>/dev/null || true
import collections, json, os, time
from datetime import datetime

path = os.environ["AMBIENT_LOG"]
window = int(os.environ.get("CHUMP_SPIN_WINDOW_S", "600"))
threshold = int(os.environ.get("CHUMP_SPIN_THRESHOLD", "20"))
now = time.time()
counts = collections.Counter()
gaps = collections.defaultdict(collections.Counter)
try:
    with open(path) as f:
        lines = f.readlines()[-4000:]
except OSError:
    lines = []
for line in lines:
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("kind") != "worker_stuck":
        continue
    reason = (e.get("reason") or "")
    if not reason.startswith("preflight_fail"):
        continue
    ts = e.get("ts", "")
    try:
        t = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        continue
    if now - t > window:
        continue
    agent = str(e.get("agent_id") or "")
    if not agent:
        continue
    counts[agent] += 1
    gid = e.get("gap_id") or ""
    if gid:
        gaps[agent][gid] += 1
for agent, n in counts.items():
    if n >= threshold:
        top_gap = gaps[agent].most_common(1)[0][0] if gaps[agent] else ""
        print(f"{agent} {n} {top_gap}")
PY
    )"

    if [[ -n "$SPIN_REPORT" ]]; then
        while IFS=' ' read -r _agent _count _gap; do
            [[ -z "$_agent" ]] && continue
            # Only act on configured worker IDs (avoid restarting a unit that
            # doesn't exist on this host).
            case " $SPIN_IDS " in *" $_agent "*) : ;; *) continue ;; esac

            _unit="chump-worker@${_agent}.service"
            _heal_state="$LOCKS_DIR/worker-spin-healed-${_agent}.ts"
            _now_epoch="$(date +%s)"
            if [[ -f "$_heal_state" ]]; then
                _last="$(cat "$_heal_state" 2>/dev/null || echo 0)"
                [[ "$_last" =~ ^[0-9]+$ ]] || _last=0
                if (( _now_epoch - _last < SPIN_HEAL_COOLDOWN_S )); then
                    _ago=$(( _now_epoch - _last ))
                    echo "[organ-watchdog] worker $_agent spinning (${_count}x preflight_fail) but healed ${_ago}s ago (< ${SPIN_HEAL_COOLDOWN_S}s) — skipping re-heal"
                    continue
                fi
            fi

            echo "[organ-watchdog] SPIN: worker $_agent emitted ${_count}x worker_stuck/preflight_fail within ${SPIN_WINDOW_S}s (offending gap: ${_gap:-unknown})"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo "[organ-watchdog]   (dry-run) would clear offending claim for ${_gap:-none} + restart $_unit"
                # scanner-anchor: "kind":"worker_spin_detected"
                emit worker_spin_detected "\"agent_id\":\"$_agent\",\"count\":$_count,\"gap_id\":\"${_gap}\",\"dry_run\":1"
                continue
            fi

            # Clear the offending stale claim so the restarted worker (and its
            # siblings) don't immediately re-pick the same failing gap: drop
            # the gap lock and write a short cluster-wide cooldown that the
            # picker's cooled_down_gaps() honors.
            if [[ -n "$_gap" ]]; then
                rm -f "$LOCKS_DIR/.gap-${_gap}.lock" 2>/dev/null || true
                mkdir -p "$LOCKS_DIR/cooldown" 2>/dev/null || true
                _cd_until=$(( _now_epoch + SPIN_WINDOW_S ))
                printf '{"gap_id":"%s","until":%d,"agent":"watchdog","ts":"%s","reason":"worker_spin_heal"}\n' \
                    "$_gap" "$_cd_until" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    > "$LOCKS_DIR/cooldown/${_gap}.json" 2>/dev/null || true
            fi

            if ! "$SYSTEMCTL_BIN" restart "$_unit" 2>&1; then
                echo "[organ-watchdog]   ERROR: restart $_unit failed" >&2
                # scanner-anchor: "kind":"worker_spin_heal_failed"  (RESILIENT-332;
                # fires when the restart of a spinning worker unit itself errors)
                emit worker_spin_heal_failed "\"agent_id\":\"$_agent\",\"unit\":\"$_unit\",\"gap_id\":\"${_gap}\""
                scan_fail=1
                continue
            fi
            echo "$_now_epoch" > "$_heal_state" 2>/dev/null || true
            echo "[organ-watchdog]   healed spinning worker $_agent (restart $_unit + cleared claim ${_gap:-none})"
            # scanner-anchor: "kind":"worker_spin_healed"  (RESILIENT-332; fires
            # when the watchdog restarts a worker that was spinning on
            # preflight_fail and clears the offending stale claim — the OS
            # acting on its own worker_stuck signal, no human step)
            emit worker_spin_healed "\"agent_id\":\"$_agent\",\"unit\":\"$_unit\",\"count\":$_count,\"gap_id\":\"${_gap}\",\"action\":\"restart+clear-claim\""
            healed=$((healed + 1))
        done <<< "$SPIN_REPORT"
    fi
fi

# ── 5. Binary + binary-refresh-organ heal (INFRA-3651, PEER-HEAL-04) ───────
# Two independent failure modes converge here, both traced to the mission's
# binary-currency promise (RESILIENT-200 / node-refresh-chump.sh):
#   (a) the release binary itself vanished or went stale — no
#       target/release/chump, or its build sha lags origin/main HEAD
#       (refresh-runner-binary.sh's own staleness rule, reused here so this
#       watchdog agrees with the refresher on what "current" means).
#   (b) the organ that's supposed to prevent (a), chump-node-refresh.service,
#       is itself dead. It is a systemd --user unit (RESILIENT-200) —
#       invisible to section 1's system-scope `systemctl list-units` scan.
#       That blind spot is exactly how it sat `failed` for 11 days unnoticed.
#
# Known gap (AC 5): reviving the --user unit from a root watchdog needs a
# resolvable XDG_RUNTIME_DIR for the unit's owning user. When systemd --user
# can't be reached (non-lingering user, no active session), the systemd path
# errors and this section falls through to the process path — a direct
# re-run of the refresh wrapper that doesn't depend on systemd at all, so the
# binary still gets current even when the unit itself can't be revived.
if [[ "${CHUMP_ORGAN_WATCHDOG_BINARY_HEAL:-0}" == "1" ]]; then
    NODE_REFRESH_SCRIPT="${CHUMP_ORGAN_WATCHDOG_NODE_REFRESH_SCRIPT:-$REPO_ROOT/scripts/ops/node-refresh-chump.sh}"

    # 5a. missing/stale release binary
    BUILT_BIN="$REPO_ROOT/target/release/chump"
    BIN_STALE=0
    BIN_STALE_REASON=""
    if [[ ! -x "$BUILT_BIN" ]]; then
        BIN_STALE=1
        BIN_STALE_REASON="missing"
    else
        BUILT_SHA="$("$BUILT_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
        MAIN_HEAD_SHA="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse --short=12 origin/main 2>/dev/null || echo "")"
        if [[ -z "$BUILT_SHA" || "$BUILT_SHA" == "unknown" ]]; then
            BIN_STALE=1
            BIN_STALE_REASON="unknown_version"
        elif [[ -n "$MAIN_HEAD_SHA" && "$BUILT_SHA" != "$MAIN_HEAD_SHA"* && "$MAIN_HEAD_SHA" != "$BUILT_SHA"* ]]; then
            BIN_STALE=1
            BIN_STALE_REASON="stale"
        fi
    fi

    if [[ "$BIN_STALE" == "1" ]]; then
        echo "[organ-watchdog] BINARY: $BUILT_BIN is $BIN_STALE_REASON vs origin/main HEAD — triggering refresh"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[organ-watchdog]   (dry-run) would run: $NODE_REFRESH_SCRIPT"
        elif [[ -x "$NODE_REFRESH_SCRIPT" ]]; then
            if NODE_AMBIENT="$AMBIENT_LOG" CHUMP_NODE_REPO="$REPO_ROOT" "$NODE_REFRESH_SCRIPT" >/dev/null 2>&1; then
                echo "[organ-watchdog]   binary refresh triggered ($BIN_STALE_REASON)"
                # scanner-anchor: "kind":"organ_binary_healed"  (INFRA-3651;
                # fires when the watchdog detects a missing/stale release
                # binary and successfully triggers node-refresh-chump.sh to
                # rebuild + reinstall it)
                emit organ_binary_healed "\"reason\":\"$BIN_STALE_REASON\",\"bin\":\"$BUILT_BIN\""
                healed=$((healed + 1))
            else
                echo "[organ-watchdog]   WARN: $NODE_REFRESH_SCRIPT failed to refresh the binary" >&2
                emit organ_self_heal_failed "\"unit\":\"binary\",\"step\":\"refresh\",\"reason\":\"$BIN_STALE_REASON\""
                scan_fail=1
            fi
        else
            echo "[organ-watchdog]   WARN: node-refresh script not found/executable: $NODE_REFRESH_SCRIPT" >&2
        fi
    fi

    # 5b. binary-refresh organ (chump-node-refresh.service, --user scope) failed
    REFRESH_UNIT="${CHUMP_BINARY_REFRESH_UNIT:-chump-node-refresh.service}"
    USER_SYSTEMCTL_BIN="${CHUMP_ORGAN_WATCHDOG_USER_SYSTEMCTL_BIN:-$SYSTEMCTL_BIN}"
    REFRESH_UNIT_FAILED="$("$USER_SYSTEMCTL_BIN" --user list-units --all --type=service --state=failed --plain --no-legend "$REFRESH_UNIT" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$REFRESH_UNIT_FAILED" ]]; then
        echo "[organ-watchdog] FAILED (binary-refresh organ, --user scope): $REFRESH_UNIT"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[organ-watchdog]   (dry-run) would reset-failed + restart --user $REFRESH_UNIT"
        elif "$USER_SYSTEMCTL_BIN" --user reset-failed "$REFRESH_UNIT" 2>&1 \
            && "$USER_SYSTEMCTL_BIN" --user restart "$REFRESH_UNIT" 2>&1; then
            echo "[organ-watchdog]   healed $REFRESH_UNIT (systemd --user path)"
            # scanner-anchor: "kind":"organ_self_healed"  (INFRA-3651 reuses
            # the same event kind as section 1 — this IS the same organ-heal
            # contract, just reached via the --user systemctl scope)
            emit organ_self_healed "\"unit\":\"$REFRESH_UNIT\",\"action\":\"reset-failed+restart--user\""
            healed=$((healed + 1))
        else
            echo "[organ-watchdog]   WARN: systemd --user reset/restart failed for $REFRESH_UNIT — falling back to process path" >&2
            if [[ "$DRY_RUN" != "1" ]] && [[ -x "$NODE_REFRESH_SCRIPT" ]] \
                && NODE_AMBIENT="$AMBIENT_LOG" CHUMP_NODE_REPO="$REPO_ROOT" "$NODE_REFRESH_SCRIPT" >/dev/null 2>&1; then
                echo "[organ-watchdog]   healed via process-path re-run of $NODE_REFRESH_SCRIPT"
                emit organ_self_healed "\"unit\":\"$REFRESH_UNIT\",\"action\":\"process-path-rerun\""
                healed=$((healed + 1))
            else
                emit organ_self_heal_failed "\"unit\":\"$REFRESH_UNIT\",\"step\":\"user-systemd-and-process-path\""
                scan_fail=1
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

# RESILIENT-356: a monitored organ that could not be healed is a FINDING, not a
# watchdog failure. It is already emitted as organ_self_heal_failed for the
# duty-officer to escalate/page. Exiting non-zero here marked the watchdog's OWN
# service `failed`, and since nothing heals the healer, a single unhealable organ
# (chump-sla-scorecard, 2026-08-20) killed the watchdog for 16h, unwatched. The
# healer must never self-immolate: emit the finding, exit clean. Non-zero is
# reserved for the watchdog's own internal breakage (missing systemctl /
# unreadable manifest — those exit 1 above).
if [[ "$scan_fail" == "1" ]]; then
    echo "[organ-watchdog] NOTE: one or more organs could not be healed this cycle — organ_self_heal_failed emitted for escalation; watchdog exiting clean so it keeps running"
fi
exit 0
