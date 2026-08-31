#!/usr/bin/env bash
# scripts/ops/node-main-sync.sh — RESILIENT-491 (slice of RESILIENT-345)
#
# WHY THIS EXISTS. RESILIENT-345 found CJ organs running a 3-day/114-commit
# STALE binary because chump-cj-sync only `git fetch`ed and never brought the
# checkout forward — merged fixes on main never reached the running node. The
# full NODE-UPDATER organ (rebuild + restart + self-test) is tracked under
# RESILIENT-345; this slice is the first, load-bearing step of that sequence:
# detect that main moved, and if so bring the local checkout to origin/main
# via `git fetch` + `git reset --hard origin/main` — logging output/exit code
# and aborting the rebuild sequence with a clear error on failure, so a later
# slice can safely chain build/swap/restart/self-test after this step
# succeeds.
#
# Usage: scripts/ops/node-main-sync.sh   (one-shot; safe to run on a cadence)
#
# Env overrides:
#   CHUMP_REPO_ROOT         repo to operate on (default: walk up from this script)
#   CHUMP_NODE_SYNC_AMBIENT ambient stream to append to (tests)
#   CHUMP_NODE_SYNC_LOGDIR  log dir override (tests)
#   CHUMP_NODE_SYNC_GIT_BIN override for `git` (tests: inject a failing stub)
#
# Emits (best-effort, appended to ambient):
#   node_main_sync_noop          local HEAD already == origin/main
#   node_main_sync_main_moved    main advanced; fetch+reset starting
#   node_main_sync_synced        fetch+reset --hard succeeded, HEAD now == origin/main
#   node_main_sync_fetch_failed  `git fetch` failed — rebuild sequence aborted
#   node_main_sync_reset_failed  `git reset --hard` failed — rebuild sequence aborted
#
# Exit codes:
#   0  no-op (already fresh) or fetch+reset succeeded
#   1  fetch failed or reset failed — rebuild sequence aborted

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="${CHUMP_NODE_SYNC_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GIT_BIN="${CHUMP_NODE_SYNC_GIT_BIN:-git}"

LOG_DIR="${CHUMP_NODE_SYNC_LOGDIR:-$REPO_ROOT/.chump-locks/node-main-sync-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/sync-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run).log"

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG" 2>/dev/null || true
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" 2>/dev/null; }
log_err() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2 2>/dev/null; }

# scanner-anchor (RESILIENT-491, docs/observability/EVENT_REGISTRY.yaml):
# scanner-anchor: "kind":"node_main_sync_noop"
# scanner-anchor: "kind":"node_main_sync_main_moved"
# scanner-anchor: "kind":"node_main_sync_synced"
# scanner-anchor: "kind":"node_main_sync_fetch_failed"
# scanner-anchor: "kind":"node_main_sync_reset_failed"

cd "$REPO_ROOT" || { log_err "FATAL: cannot cd $REPO_ROOT"; exit 1; }

LOCAL_SHA_BEFORE="$("$GIT_BIN" rev-parse HEAD 2>/dev/null || echo unknown)"

# ── fetch: this is also how we detect main_moved (compare HEAD to the
# freshly-fetched origin/main), so it always runs first. ────────────────────
FETCH_OUTPUT="$("$GIT_BIN" fetch origin main 2>&1)"
FETCH_RC=$?
printf '%s\n' "$FETCH_OUTPUT" >> "$LOG" 2>/dev/null || true
log "git fetch origin main exited $FETCH_RC"

if [[ "$FETCH_RC" -ne 0 ]]; then
    log_err "FATAL: git fetch failed (rc=$FETCH_RC) — aborting rebuild sequence"
    log_err "$FETCH_OUTPUT"
    FETCH_ERR_ESCAPED="$(printf '%s' "$FETCH_OUTPUT" | head -c 500 | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')"
    emit node_main_sync_fetch_failed "\"rc\":$FETCH_RC,\"output\":\"$FETCH_ERR_ESCAPED\""
    exit 1
fi

MAIN_SHA="$("$GIT_BIN" rev-parse origin/main 2>/dev/null || echo "$LOCAL_SHA_BEFORE")"

if [[ "$LOCAL_SHA_BEFORE" == "$MAIN_SHA" ]]; then
    log "no-op: main_moved=false — local HEAD already == origin/main ($LOCAL_SHA_BEFORE)"
    emit node_main_sync_noop "\"sha\":\"$LOCAL_SHA_BEFORE\""
    exit 0
fi

log "MAIN MOVED: main_moved=true ($LOCAL_SHA_BEFORE -> $MAIN_SHA) — resetting to origin/main"
emit node_main_sync_main_moved "\"from\":\"$LOCAL_SHA_BEFORE\",\"to\":\"$MAIN_SHA\""

RESET_OUTPUT="$("$GIT_BIN" reset --hard origin/main 2>&1)"
RESET_RC=$?
printf '%s\n' "$RESET_OUTPUT" >> "$LOG" 2>/dev/null || true
log "git reset --hard origin/main exited $RESET_RC"

if [[ "$RESET_RC" -ne 0 ]]; then
    log_err "FATAL: git reset --hard failed (rc=$RESET_RC) — aborting rebuild sequence"
    log_err "$RESET_OUTPUT"
    emit node_main_sync_reset_failed "\"rc\":$RESET_RC,\"from\":\"$LOCAL_SHA_BEFORE\",\"to\":\"$MAIN_SHA\""
    exit 1
fi

LOCAL_SHA_AFTER="$("$GIT_BIN" rev-parse HEAD 2>/dev/null || echo unknown)"
log "synced: HEAD now $LOCAL_SHA_AFTER"
emit node_main_sync_synced "\"sha\":\"$LOCAL_SHA_AFTER\""
exit 0
