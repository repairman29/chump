#!/usr/bin/env bash
# github-liaison.sh — INFRA-1317 (Phase 1 of docs/design/GITHUB_LIAISON.md)
#
# Elects ONE fleet process as the "GitHub Liaison" — the sole reader of the
# GitHub API. Other workers read from .chump/github_cache.db via the existing
# cache_lookup_* helpers in scripts/coord/lib/github_cache.sh.
#
# Phase 1 contract (this file):
#   - Lockdir election on .chump-locks/github-liaison.lock/ (atomic mkdir).
#   - Heartbeat file inside the lockdir; refreshed every cycle. Stale > 90s
#     → another invocation may take over.
#   - Refresh loop: each cycle calls scripts/ops/github-cache-reconcile.sh
#     (one REST call → all open PRs). Default poll interval 60s, overridable
#     via CHUMP_LIAISON_POLL_INTERVAL_S.
#   - Opt-in via CHUMP_LIAISON_ENABLED=1 (default OFF, for safety during Phase 1).
#
# Out of scope (later phases):
#   - Webhook queue drain (Phase 2, INFRA-1313).
#   - NATS mutation routing (Phase 3, INFRA-1314).
#   - GitHub App token distribution (Phase 4, INFRA-1076).
#
# Usage:
#   scripts/ops/github-liaison.sh              # daemon mode (loops until killed)
#   scripts/ops/github-liaison.sh --once       # single refresh cycle then exit
#   scripts/ops/github-liaison.sh --check      # exit 0 if liaison healthy, else 1
#   scripts/ops/github-liaison.sh --release    # release lock if we hold it
#
# Env:
#   CHUMP_LIAISON_ENABLED          (default 0) — daemon refuses to start unless 1
#   CHUMP_LIAISON_POLL_INTERVAL_S  (default 60) — seconds between refresh cycles
#   CHUMP_LIAISON_STALE_S          (default 90) — heartbeat age that triggers takeover
#   CHUMP_LIAISON_LOCK_DIR         override the lockdir (default <repo>/.chump-locks/github-liaison.lock)
#   CHUMP_AMBIENT_LOG              override the ambient stream path
#
# Ambient events emitted (registered in docs/observability/EVENT_REGISTRY.yaml):
#   liaison_elected   — this process acquired the liaison lock
#   liaison_heartbeat — periodic per-cycle heartbeat (includes prs_refreshed)
#   liaison_takeover  — reclaimed a stale lock from a dead prior liaison
#   liaison_yielded   — graceful exit; lock removed
#
# Exit codes:
#   0 — normal (single-cycle done, --check OK, daemon shut down cleanly,
#       OR second invocation found an existing fresh liaison and stood down)
#   1 — --check failed (no fresh liaison detected)
#   2 — daemon mode requested but CHUMP_LIAISON_ENABLED != 1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
cd "$REPO" || exit 1

LOCK_DIR="${CHUMP_LIAISON_LOCK_DIR:-$REPO/.chump-locks/github-liaison.lock}"
HEARTBEAT="$LOCK_DIR/heartbeat"
HOLDER_FILE="$LOCK_DIR/holder"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
POLL_INTERVAL_S="${CHUMP_LIAISON_POLL_INTERVAL_S:-60}"
STALE_S="${CHUMP_LIAISON_STALE_S:-90}"
RECONCILE_SCRIPT="$REPO/scripts/ops/github-cache-reconcile.sh"

# ── INFRA-1875: webhook-health probe + polling fallback ────────────────────
# Each refresh cycle, POST a heartbeat ping to the local
# github-webhook-receiver. If it fails CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS
# times consecutively, drop the poll interval to CHUMP_LIAISON_POLL_FALLBACK_S
# and emit liaison_webhook_unhealthy + liaison_polling_fallback_active. On the
# next successful probe, restore the original interval + emit liaison_webhook_recovered.
WEBHOOK_HEALTH_URL="${CHUMP_LIAISON_WEBHOOK_HEALTH_URL:-http://127.0.0.1:8765/health}"
WEBHOOK_HEALTH_MAX_FAILS="${CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS:-3}"
POLL_FALLBACK_S="${CHUMP_LIAISON_POLL_FALLBACK_S:-30}"
WEBHOOK_HEALTH_DISABLED="${CHUMP_LIAISON_WEBHOOK_HEALTH_DISABLED:-0}"
# Internal runtime state (NOT operator-tunable; tracks consecutive-fail count
# + whether we are currently in fallback mode).
_LIAISON_WEBHOOK_FAILS=0
_LIAISON_IN_FALLBACK=0
_LIAISON_ORIGINAL_INTERVAL_S="$POLL_INTERVAL_S"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null

_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

# _emit_ambient <kind> <key1=val1> [key2=val2 ...]
# Values are JSON-safe strings; numerics are passed as-is when caller already
# formatted them (we don't quote). Keep this self-contained — ambient-emit.sh
# spawns a subshell and we want to keep the daemon hot.
_emit_ambient() {
    local kind="$1"; shift
    local ts; ts="$(_now_utc)"
    local fields=""
    while [[ $# -gt 0 ]]; do
        local kv="$1"; shift
        local key="${kv%%=*}"
        local val="${kv#*=}"
        # If val is a bare number/bool, leave unquoted; else quote.
        if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [[ "$val" == "true" ]] || [[ "$val" == "false" ]]; then
            fields+=",\"$key\":$val"
        else
            # Escape backslashes + quotes.
            val="${val//\\/\\\\}"
            val="${val//\"/\\\"}"
            fields+=",\"$key\":\"$val\""
        fi
    done
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "$fields" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# _heartbeat_age_s — prints integer seconds since the heartbeat file's mtime,
# or empty if no heartbeat exists.
_heartbeat_age_s() {
    [[ -f "$HEARTBEAT" ]] || return 1
    local mtime now
    # macOS stat -f, Linux stat -c
    mtime=$(stat -f %m "$HEARTBEAT" 2>/dev/null || stat -c %Y "$HEARTBEAT" 2>/dev/null)
    [[ -n "$mtime" ]] || return 1
    now=$(_now_epoch)
    printf '%d' "$((now - mtime))"
}

# _try_acquire_lock — attempts atomic mkdir. Returns 0 on success, 1 on contention
# (another process holds a fresh lock), 2 on stale-lock takeover.
_try_acquire_lock() {
    mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        _now_utc > "$HEARTBEAT"
        printf '%s:%s\n' "$(hostname -s 2>/dev/null || echo unknown)" "$$" > "$HOLDER_FILE"
        return 0
    fi
    # Lock exists. Check staleness.
    local age
    age="$(_heartbeat_age_s 2>/dev/null || echo "")"
    if [[ -z "$age" ]] || [[ "$age" -gt "$STALE_S" ]]; then
        # Stale — take it over.
        local prev_holder; prev_holder="$(cat "$HOLDER_FILE" 2>/dev/null || echo unknown)"
        rm -rf "$LOCK_DIR" 2>/dev/null
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            _now_utc > "$HEARTBEAT"
            printf '%s:%s\n' "$(hostname -s 2>/dev/null || echo unknown)" "$$" > "$HOLDER_FILE"
            _emit_ambient liaison_takeover \
                "prev_holder=$prev_holder" \
                "stale_age_s=${age:-unknown}" \
                "pid=$$"
            return 2
        fi
        # mkdir raced — another process won. Treat as contention.
        return 1
    fi
    return 1
}

_we_hold_lock() {
    [[ -f "$HOLDER_FILE" ]] || return 1
    local holder; holder="$(cat "$HOLDER_FILE" 2>/dev/null || echo "")"
    local me; me="$(hostname -s 2>/dev/null || echo unknown):$$"
    [[ "$holder" == "$me" ]]
}

_release_lock() {
    # Permissive: an operator running `--release` from a different shell PID
    # should still be able to free a stuck lock. The lockdir contents tell us
    # who held it; we record that for the yielded event.
    if [[ -d "$LOCK_DIR" ]]; then
        local holder; holder="$(cat "$HOLDER_FILE" 2>/dev/null || echo unknown)"
        rm -rf "$LOCK_DIR" 2>/dev/null
        _emit_ambient liaison_yielded "pid=$$" "released_holder=$holder" "reason=clean_exit"
    fi
}

_refresh_cycle() {
    # Renew heartbeat first (so any peer checking sees us alive).
    _now_utc > "$HEARTBEAT" 2>/dev/null || true

    # INFRA-1875: probe the webhook receiver before reconcile. The probe is
    # cheap (a localhost GET); failure → consecutive-fail counter; on threshold
    # cross → drop poll interval to fallback + emit unhealthy event. On
    # recovery, restore interval + emit recovered event.
    if [[ "$WEBHOOK_HEALTH_DISABLED" != "1" ]]; then
        local probe_err=""
        # Use curl with strict timeout; -fsS hides progress but surfaces HTTP errors.
        if probe_err=$(curl -fsS --max-time 5 "$WEBHOOK_HEALTH_URL" -o /dev/null 2>&1); then
            # Probe succeeded.
            if [[ "$_LIAISON_IN_FALLBACK" == "1" ]]; then
                # Recovery path: restore the operator's original interval + announce.
                POLL_INTERVAL_S="$_LIAISON_ORIGINAL_INTERVAL_S"
                _LIAISON_IN_FALLBACK=0
                _emit_ambient liaison_webhook_recovered \
                    "pid=$$" \
                    "poll_interval_s=$POLL_INTERVAL_S" \
                    "url=$WEBHOOK_HEALTH_URL"
            fi
            _LIAISON_WEBHOOK_FAILS=0
        else
            _LIAISON_WEBHOOK_FAILS=$((_LIAISON_WEBHOOK_FAILS + 1))
            if [[ "$_LIAISON_WEBHOOK_FAILS" -ge "$WEBHOOK_HEALTH_MAX_FAILS" ]] \
               && [[ "$_LIAISON_IN_FALLBACK" != "1" ]]; then
                # Threshold crossed for the first time this run. Sanitize the
                # error message for the JSON field (truncate, strip quotes).
                local last_err
                last_err=$(printf '%s' "$probe_err" | tr -d '"' | head -c 200)
                _emit_ambient liaison_webhook_unhealthy \
                    "pid=$$" \
                    "consecutive_failures=$_LIAISON_WEBHOOK_FAILS" \
                    "url=$WEBHOOK_HEALTH_URL" \
                    "last_error=$last_err"
                POLL_INTERVAL_S="$POLL_FALLBACK_S"
                _LIAISON_IN_FALLBACK=1
                _emit_ambient liaison_polling_fallback_active \
                    "pid=$$" \
                    "poll_interval_s=$POLL_INTERVAL_S" \
                    "reason=webhook_unhealthy_after_${WEBHOOK_HEALTH_MAX_FAILS}_failures"
            fi
        fi
    fi

    # One batch reconcile — this is the existing one-REST-call refresh that
    # already migrates pr_state for all open PRs.
    local refreshed=0
    if [[ -x "$RECONCILE_SCRIPT" ]]; then
        # Capture exit status but don't fail the cycle on transient errors.
        if "$RECONCILE_SCRIPT" >/dev/null 2>&1; then
            refreshed=1
        fi
    fi

    _emit_ambient liaison_heartbeat \
        "pid=$$" \
        "interval_s=$POLL_INTERVAL_S" \
        "reconcile_ok=$refreshed"
}

# ── command handling ─────────────────────────────────────────────────────────
MODE="daemon"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --once)    MODE="once";    shift ;;
        --check)   MODE="check";   shift ;;
        --release) MODE="release"; shift ;;
        -h|--help)
            sed -n '1,40p' "$0"; exit 0 ;;
        *)
            echo "github-liaison.sh: unknown arg: $1" >&2
            exit 2 ;;
    esac
done

case "$MODE" in
    check)
        # Exit 0 iff a fresh liaison heartbeat exists.
        age="$(_heartbeat_age_s 2>/dev/null || echo "")"
        if [[ -n "$age" ]] && [[ "$age" -le "$STALE_S" ]]; then
            holder="$(cat "$HOLDER_FILE" 2>/dev/null || echo unknown)"
            echo "github-liaison: healthy (holder=$holder, heartbeat_age=${age}s)"
            exit 0
        fi
        echo "github-liaison: no fresh liaison (age=${age:-unknown}s, stale_threshold=${STALE_S}s)" >&2
        exit 1
        ;;
    release)
        _release_lock
        exit 0
        ;;
    once|daemon)
        # INFRA-1876: offline-mode hard gate. When CHUMP_GITHUB_MODE=offline
        # the daemon refuses to start — no lock acquisition, no REST cycle.
        # Exits 0 because "offline" is a deliberate operator stance, not a fault.
        if [[ "$MODE" == "daemon" ]] && [[ "${CHUMP_GITHUB_MODE:-}" == "offline" ]]; then
            echo "github-liaison: offline mode — Liaison disabled" >&2
            _emit_ambient liaison_offline_mode_gated "pid=$$" "mode=$MODE"
            exit 0
        fi

        # daemon mode requires opt-in; --once is unguarded (used by CI tests
        # and chump-fleet-bootstrap dry-runs).
        if [[ "$MODE" == "daemon" ]] && [[ "${CHUMP_LIAISON_ENABLED:-0}" != "1" ]]; then
            echo "github-liaison: CHUMP_LIAISON_ENABLED != 1; daemon disabled (Phase 1 safety default)" >&2
            exit 2
        fi

        # Try to acquire. Three outcomes:
        #   0 — fresh acquire     → continue
        #   1 — contention        → stand down
        #   2 — stale takeover    → continue (event already emitted)
        _try_acquire_lock
        rc=$?
        case "$rc" in
            0)
                _emit_ambient liaison_elected "pid=$$" "stale_takeover=false"
                ;;
            1)
                # Another fresh liaison exists — exit cleanly.
                holder="$(cat "$HOLDER_FILE" 2>/dev/null || echo unknown)"
                age="$(_heartbeat_age_s 2>/dev/null || echo "")"
                echo "github-liaison: another liaison is healthy (holder=$holder, age=${age}s); standing down"
                exit 0
                ;;
            2)
                : # takeover event already emitted in _try_acquire_lock
                ;;
        esac

        if [[ "$MODE" == "once" ]]; then
            # --once: do one refresh cycle and exit. The lock stays held
            # (heartbeat fresh) so subsequent invocations see us as alive.
            # Use --release to drop the lock explicitly.
            _refresh_cycle
            exit 0
        fi

        # Daemon mode: release on signal/exit.
        trap '_release_lock; exit 0' INT TERM HUP
        trap '_release_lock' EXIT

        # Daemon loop. Re-verify holdership each cycle in case a peer
        # forcibly stole the lock (e.g. operator ran `--release`).
        while true; do
            if ! _we_hold_lock; then
                echo "github-liaison: lock lost; exiting daemon loop" >&2
                exit 0
            fi
            _refresh_cycle
            sleep "$POLL_INTERVAL_S"
        done
        ;;
esac
