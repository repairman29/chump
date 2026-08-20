#!/usr/bin/env bash
# scripts/ops/node-updater.sh — RESILIENT-345
#
# WHY THIS EXISTS. 2026-08-20 incident: CJ organs were running a 3-day /
# 114-commit-STALE binary (built 08-17, main was 08-20). That binary was
# PROVEN to miss the CREDIBLE-291 farmer-format fix that shipped hours
# earlier that day: the farmer was force-RED, and the stale binary still
# returned the OLD farmer-RED shape instead of the new format-error shape.
# The mechanism running on CJ ("chump-cj-sync") only `git fetch`ed — it
# never rebuilt the binary, so merged fixes never reached the process
# actually executing on the node. merged != running at NODE scale: every
# fix landed on main and simply never arrived where it mattered.
#
# This organ closes that loop: on main-move it (1) pulls + rebuilds +
# atomically swaps the binary (delegates to node-refresh-chump.sh — RESILIENT-200
# already solved pull+build+swap correctly, including the green-main pin;
# no need to re-invent it here), (2) restarts every OTHER running
# housekeeping organ so they re-exec against the fresh binary instead of
# quietly continuing to run the stale in-memory one, and (3) self-tests
# the result.
#
# The self-test is the other half of the incident: a binary that
# executes fine is NOT proof it's current. `chump --version` linking and
# running successfully told CJ nothing about the 114-commit gap. The
# self-test here calls `chump self-check-staleness --json` and checks the
# COMMIT delta against origin/main, not just "does the binary run".
#
# COTG: installed via the housekeeping ORGANS table
# (scripts/setup/install-node-housekeeping.sh) — every owned node gets
# this organ for free, host-agnostic (systemd / runit / nohup).
#
# Usage: scripts/ops/node-updater.sh   (one-shot; the ORGANS table's
#   write_runner wraps it in the cadence loop, default 300s)
#
# Env overrides:
#   CHUMP_REPO_ROOT              repo to operate on (default: walk up from this script)
#   CHUMP_STATE_DIR              state dir holding organs/ (default: ~/.chump)
#   CHUMP_NODE_BIN                installed binary path (default: ~/.local/bin/chump)
#   NODE_AMBIENT                  ambient stream to append to
#   CHUMP_NODE_UPDATER_REFRESH_SCRIPT   override for node-refresh-chump.sh (tests)
#   CHUMP_NODE_UPDATER_SYSTEMCTL_BIN    override for systemctl (tests)
#   CHUMP_NODE_UPDATER_HOUSEKEEPING     override for the housekeeping installer
#                                        script whose ORGANS table is read (tests)
#
# Emits (best-effort, appended to NODE_AMBIENT):
#   node_updater_noop               local HEAD already == origin/main
#   node_updater_main_moved         main advanced; rebuild starting
#   node_updater_failed             refresh (pull/build/swap) step failed
#   node_updater_organs_restarted   N sibling organs restarted post-swap
#   node_updater_self_test_passed   post-restart binary is FRESH vs origin/main
#   node_updater_self_test_failed   binary runs but is STALE/CRITICAL_STALE
#     (freshness, not linkage — a binary that executes but is behind still
#     fails self-test)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
TARGET_BIN="${CHUMP_NODE_BIN:-$HOME/.local/bin/chump}"
AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REFRESH_SCRIPT="${CHUMP_NODE_UPDATER_REFRESH_SCRIPT:-$SCRIPT_DIR/node-refresh-chump.sh}"
SYSTEMCTL_BIN="${CHUMP_NODE_UPDATER_SYSTEMCTL_BIN:-systemctl}"
HOUSEKEEPING_INSTALLER="${CHUMP_NODE_UPDATER_HOUSEKEEPING:-$REPO_ROOT/scripts/setup/install-node-housekeeping.sh}"
SELF_NAME="node-updater"

LOG_DIR="${CHUMP_NODE_UPDATER_LOGDIR:-$STATE_DIR/node-updater-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/update-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run).log"

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$AMBIENT")" ]] && printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG" 2>/dev/null || true
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" 2>/dev/null; }
log_err() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2 2>/dev/null; }

# scanner-anchor (RESILIENT-345, docs/observability/EVENT_REGISTRY.yaml):
# scanner-anchor: "kind":"node_updater_noop"
# scanner-anchor: "kind":"node_updater_main_moved"
# scanner-anchor: "kind":"node_updater_failed"
# scanner-anchor: "kind":"node_updater_organs_restarted"
# scanner-anchor: "kind":"node_updater_self_test_passed"
# scanner-anchor: "kind":"node_updater_self_test_failed"

# ── read organ names out of the tracked ORGANS table (single source of
# truth — the same table install-node-housekeeping.sh installs from) ────────
organ_names() {
    [[ -f "$HOUSEKEEPING_INSTALLER" ]] || return 0
    sed -n '/^ORGANS="/,/"$/p' "$HOUSEKEEPING_INSTALLER" \
        | sed '1s/^ORGANS="//; $s/"$//' \
        | while IFS='|' read -r name _script _cadence; do
            [[ -z "$name" ]] && continue
            [[ "$name" == "$SELF_NAME" ]] && continue
            printf '%s\n' "$name"
        done
}

# ── restart every OTHER organ so it re-execs against the fresh binary ──────
# NB: stdout is the caller's count channel (`RESTARTED_COUNT="$(restart_organs)"`)
# — every diagnostic line in here MUST go to stderr (log_err, not log) or it
# corrupts the captured count.
restart_organs() {
    local restarted=0
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 \
            && "$SYSTEMCTL_BIN" list-unit-files "chump-$name.service" --no-legend 2>/dev/null | grep -q "chump-$name.service"; then
            if "$SYSTEMCTL_BIN" restart "chump-$name.service" 2>/dev/null; then
                log_err "restarted (systemd) chump-$name.service"
                restarted=$((restarted + 1))
                continue
            fi
            log_err "WARN: systemctl restart chump-$name.service failed; trying nohup fallback"
        fi
        # nohup fallback: kill the tracked pid (if any) and relaunch the runner
        local pidfile="$STATE_DIR/organs/$name.pid"
        local runner="$STATE_DIR/organs/$name.sh"
        if [[ -f "$pidfile" ]]; then
            local old_pid; old_pid="$(cat "$pidfile" 2>/dev/null || echo)"
            [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
        fi
        if [[ -x "$runner" ]]; then
            nohup bash "$runner" >/dev/null 2>&1 &
            echo $! > "$pidfile" 2>/dev/null || true
            log_err "restarted (nohup) $name"
            restarted=$((restarted + 1))
        fi
    done < <(organ_names)
    echo "$restarted"
}

# ── self-test: FRESHNESS, not linkage. A binary that executes cleanly but
# is N commits behind origin/main must FAIL this test. ──────────────────────
self_test() {
    local bin="$1"
    if [[ ! -x "$bin" ]]; then
        log "SELF-TEST FAIL: $bin missing or not executable"
        emit node_updater_self_test_failed "\"reason\":\"binary_missing\""
        return 1
    fi
    local report rc
    report="$("$bin" self-check-staleness --json 2>/dev/null)"
    rc=$?
    local commits_behind
    commits_behind="$(printf '%s' "$report" | grep -o '"commits_behind":[0-9]*' | head -1 | cut -d: -f2)"
    if [[ "$rc" -ne 0 ]]; then
        log "SELF-TEST FAIL: binary executes but is STALE/CRITICAL_STALE (commits_behind=${commits_behind:-unknown}, exit=$rc)"
        emit node_updater_self_test_failed "\"reason\":\"stale\",\"commits_behind\":${commits_behind:-null},\"exit_code\":$rc"
        return 1
    fi
    log "SELF-TEST PASS: binary FRESH (commits_behind=${commits_behind:-0})"
    emit node_updater_self_test_passed "\"commits_behind\":${commits_behind:-0}"
    return 0
}

cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit node_updater_failed "\"reason\":\"cwd_failed\""; exit 1; }

git fetch origin main --quiet 2>>"$LOG" || log "WARN: git fetch failed (offline?); using local repo state"

LOCAL_SHA_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
MAIN_SHA="$(git rev-parse origin/main 2>/dev/null || echo "$LOCAL_SHA_BEFORE")"

if [[ "$LOCAL_SHA_BEFORE" == "$MAIN_SHA" ]]; then
    log "no-op: local HEAD already == origin/main ($LOCAL_SHA_BEFORE)"
    emit node_updater_noop "\"sha\":\"$LOCAL_SHA_BEFORE\""
    self_test "$TARGET_BIN"
    exit $?
fi

log "MAIN MOVED: $LOCAL_SHA_BEFORE -> $MAIN_SHA — pull + rebuild + swap"
emit node_updater_main_moved "\"from\":\"$LOCAL_SHA_BEFORE\",\"to\":\"$MAIN_SHA\""

if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    log "FATAL: refresh script missing/not executable: $REFRESH_SCRIPT"
    emit node_updater_failed "\"reason\":\"refresh_script_missing\""
    exit 1
fi

CHUMP_NODE_REPO="$REPO_ROOT" CHUMP_NODE_BIN="$TARGET_BIN" NODE_AMBIENT="$AMBIENT" \
    bash "$REFRESH_SCRIPT" >>"$LOG" 2>&1
refresh_rc=$?
if [[ "$refresh_rc" -ne 0 ]]; then
    log "FATAL: $REFRESH_SCRIPT exited $refresh_rc; see $LOG"
    emit node_updater_failed "\"reason\":\"refresh_failed\",\"rc\":$refresh_rc"
    exit 1
fi

RESTARTED_COUNT="$(restart_organs)"
log "restarted $RESTARTED_COUNT sibling organ(s) post-swap"
emit node_updater_organs_restarted "\"count\":${RESTARTED_COUNT:-0}"

self_test "$TARGET_BIN"
exit $?
