#!/usr/bin/env bash
# scripts/ops/auto-deploy.sh — MISSION-012
#
# Auto-deploy daemon: ensures the installed /opt/homebrew/bin/chump binary
# tracks origin/main.  Called by the com.chump.auto-deploy launchd agent
# every 1200s (~20 min).
#
# Logic:
#   (a) git fetch origin main                             — get latest remote state
#   (b) compare origin/main HEAD SHA to stored last-deployed SHA
#   (c) if advanced → delegate to refresh-runner-binary.sh (isolated build)
#   (d) on success → record new deployed SHA
#   (e) emit ambient kind=binary_auto_deployed
#
# Build isolation guarantee: this script NEVER checks out main or modifies the
# main worktree.  All building is delegated to refresh-runner-binary.sh which
# creates an isolated detached git worktree in /tmp, builds, installs, then
# tears it down.  The main checkout's local state is untouched.
#
# Idempotent: exits 0 (no-op) when the installed binary is already current.
#
# Environment overrides:
#   CHUMP_REPO_ROOT               — repo root (default: resolved relative to script)
#   CHUMP_REFRESH_RUNNER_SCRIPT   — path to refresh-runner-binary.sh
#   CHUMP_SKIP_AUTO_DEPLOY        — set 1 to exit 0 immediately (bypass)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
STATE_DIR="$REPO_ROOT/.chump-locks"
DEPLOYED_SHA_FILE="$STATE_DIR/auto-deploy-last-sha.txt"
LOG_DIR="$REPO_ROOT/.chump-locks/auto-deploy-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/auto-deploy-$(date -u +%Y%m%dT%H%M%SZ).log"

# scanner-anchor: "kind":"binary_auto_deployed"
emit_ambient() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Bypass
if [[ "${CHUMP_SKIP_AUTO_DEPLOY:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_AUTO_DEPLOY=1"
    exit 0
fi

REFRESH_SCRIPT="${CHUMP_REFRESH_RUNNER_SCRIPT:-$REPO_ROOT/scripts/setup/refresh-runner-binary.sh}"
if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    log "FATAL: refresh script not executable: $REFRESH_SCRIPT"
    emit_ambient "binary_auto_deploy_failed" "\"reason\":\"no_refresh_script\",\"path\":\"$REFRESH_SCRIPT\""
    exit 1
fi

cd "$REPO_ROOT" || { log "FATAL: cannot cd to $REPO_ROOT"; exit 1; }

# (a) Fetch latest main
git fetch origin main --quiet 2>>"$LOG" || {
    log "WARN: git fetch failed (offline?); proceeding with local state"
}

# (b) Get origin/main HEAD SHA
MAIN_SHA="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)"
MAIN_SHA_SHORT="${MAIN_SHA:0:12}"
log "origin/main HEAD = $MAIN_SHA_SHORT"

# Load last-deployed SHA (empty = never deployed by auto-deploy)
LAST_SHA=""
if [[ -f "$DEPLOYED_SHA_FILE" ]]; then
    LAST_SHA="$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null | tr -d '[:space:]')"
fi

if [[ -n "$LAST_SHA" && "$LAST_SHA" == "$MAIN_SHA" ]]; then
    log "SKIP: origin/main has not advanced since last auto-deploy (sha=$MAIN_SHA_SHORT)"
    emit_ambient "binary_auto_deploy_skipped" "\"reason\":\"already_current\",\"sha\":\"$MAIN_SHA_SHORT\""
    # Prune old logs (keep last 24)
    ls -t "$LOG_DIR"/auto-deploy-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true
    exit 0
fi

log "DEPLOY: origin/main advanced (last_deployed=${LAST_SHA:-none}, current=$MAIN_SHA_SHORT)"

# (c) Delegate to refresh-runner-binary.sh (isolated worktree build)
# That script handles: create detached worktree → cargo build --release → hardcopy → teardown
TARGET_BIN="${CHUMP_RUNNER_BIN:-/opt/homebrew/bin/chump}"
PREV_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"

log "calling refresh-runner-binary.sh (prev_installed_sha=$PREV_SHA)"
if CHUMP_REPO_ROOT="$REPO_ROOT" bash "$REFRESH_SCRIPT" >>"$LOG" 2>&1; then
    NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "OK: rebuild complete — prev=$PREV_SHA new=$NEW_SHA main=$MAIN_SHA_SHORT"

    # (d) Record deployed SHA
    printf '%s\n' "$MAIN_SHA" > "$DEPLOYED_SHA_FILE"

    # (e) Emit binary_auto_deployed
    emit_ambient "binary_auto_deployed" \
        "\"prev_sha\":\"$PREV_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA_SHORT\""
else
    log "FAIL: refresh-runner-binary.sh exited non-zero; binary may be stale"
    emit_ambient "binary_auto_deploy_failed" \
        "\"reason\":\"refresh_script_failed\",\"prev_sha\":\"$PREV_SHA\",\"main_sha\":\"$MAIN_SHA_SHORT\""
    exit 1
fi

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/auto-deploy-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true

exit 0
