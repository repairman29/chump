#!/usr/bin/env bash
# scripts/ops/node-refresh-chump.sh — RESILIENT-200
#
# Linux-node counterpart of scripts/setup/refresh-runner-binary.sh (which is the
# macOS launchd auto-deploy path). Keeps a fleet node's installed `chump` binary
# current with origin/main by rebuilding from a local mirror checkout and
# installing to the node's chump path.
#
# WHY a separate script: refresh-runner-binary.sh hardcodes macOS assumptions —
# /opt/homebrew/bin target, codesign-before-swap (syspolicyd), aarch64 cargo
# paths. The Linux fleet nodes (closetjunky, Helsinki) have none of those: no
# codesign, x86_64, and a per-user ~/.local/bin (or root /usr/local/bin) target.
# This script is the Linux-shaped equivalent, driven by a systemd --user timer
# (see scripts/setup/install-node-refresh-systemd.sh).
#
# PAUSE SAFETY (RESILIENT-073): this script ONLY refreshes the binary. It never
# reads, writes, or bumps ~/.chump/AUTONOMY_LEVEL, and never starts fleet work.
# A paused node (AUTONOMY_LEVEL=0) stays paused across refreshes — the binary
# gets current, the fleet stays off until the operator flips the switch.
#
# Idempotent: if the installed binary's build SHA already matches origin/main
# HEAD, skips the rebuild entirely (fast no-op, no cargo invocation).
#
# Emits (appended to $NODE_AMBIENT if it exists, else logfile only):
#   node_binary_refreshed         — successful rebuild + install
#   node_binary_refresh_skipped   — binary already current (no-op)
#   node_binary_refresh_failed    — build or install error
#
# Bypass: CHUMP_SKIP_NODE_REFRESH=1 short-circuits to exit 0.
#
# Env overrides:
#   CHUMP_NODE_REPO   repo mirror to build from   (default: first of
#                     ~/chump-host, ~/Projects/Chump, ~/chump that exists)
#   CHUMP_NODE_BIN    install destination         (default: ~/.local/bin/chump)
#   NODE_AMBIENT      ambient stream to append to (default: <repo>/.chump-locks/ambient.jsonl)

set -uo pipefail

# --- resolve the mirror checkout to build from -------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for candidate in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        if [[ -d "$candidate/.git" ]]; then REPO_ROOT="$candidate"; break; fi
    done
fi
TARGET_BIN="${CHUMP_NODE_BIN:-$HOME/.local/bin/chump}"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LOG_DIR="${CHUMP_NODE_REFRESH_LOGDIR:-$HOME/.chump/node-refresh-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

if [[ "${CHUMP_SKIP_NODE_REFRESH:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_NODE_REFRESH=1"; exit 0
fi

if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
    log "FATAL: no chump mirror checkout found (set CHUMP_NODE_REPO)"
    emit node_binary_refresh_failed "\"reason\":\"no_repo\""
    exit 1
fi
cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit node_binary_refresh_failed "\"reason\":\"cwd_failed\""; exit 1; }

# --- fetch + fast-forward the mirror to origin/main --------------------------
# These nodes are pure BUILD MIRRORS (no operator WIP), so a hard reset to
# origin/main is the correct "make current" operation. If a node ever grows a
# real working tree, guard this behind a clean-tree check.
git fetch origin main --quiet 2>>"$LOG" || log "WARN: git fetch failed (offline?); building local main"
MAIN_SHA="$(git rev-parse --short=12 origin/main 2>/dev/null || git rev-parse --short=12 HEAD)"
log "origin/main = $MAIN_SHA  (repo: $REPO_ROOT)"

INSTALLED_SHA="none"
if [[ -x "$TARGET_BIN" ]]; then
    INSTALLED_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "installed $TARGET_BIN sha = $INSTALLED_SHA"
fi

# Idempotency: SHAs match → skip (no cargo).
if [[ "$INSTALLED_SHA" == "$MAIN_SHA"* || "$MAIN_SHA" == "$INSTALLED_SHA"* ]] \
   && [[ "$INSTALLED_SHA" != "none" && "$INSTALLED_SHA" != "unknown" ]]; then
    log "SKIP: binary already current ($INSTALLED_SHA)"
    emit node_binary_refresh_skipped "\"reason\":\"already_current\",\"sha\":\"$INSTALLED_SHA\""
    exit 0
fi

git reset --hard "origin/main" >>"$LOG" 2>&1 || {
    log "FATAL: git reset --hard origin/main failed"
    emit node_binary_refresh_failed "\"reason\":\"reset_failed\""
    exit 1
}

# --- resolve cargo -----------------------------------------------------------
CARGO=""
for candidate in "$HOME/.cargo/bin/cargo" "$(command -v cargo 2>/dev/null)" "/usr/local/bin/cargo"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then CARGO="$candidate"; break; fi
done
if [[ -z "$CARGO" ]]; then
    log "FATAL: cargo not found"; emit node_binary_refresh_failed "\"reason\":\"no_cargo\""; exit 1
fi
log "using cargo: $CARGO"

# Build --release into the repo's OWN (warm) target dir. No detached worktree:
# unlike the macOS runner, these nodes have no concurrent self-hosted-runner
# builds racing the tree, and the mirror IS the build tree.
log "cargo build --release --bin chump (warm target $REPO_ROOT/target) …"
if ! PATH="$(dirname "$CARGO"):$PATH" "$CARGO" build --release --bin chump >>"$LOG" 2>&1; then
    log "FATAL: cargo build failed; see $LOG"
    emit node_binary_refresh_failed "\"reason\":\"cargo_build_failed\""
    exit 1
fi
BUILT_BIN="$REPO_ROOT/target/release/chump"
if [[ ! -x "$BUILT_BIN" ]]; then
    log "FATAL: $BUILT_BIN missing after build"
    emit node_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
    exit 1
fi

# --- atomic install (tempfile + rename); no codesign on Linux ----------------
mkdir -p "$(dirname "$TARGET_BIN")" 2>/dev/null || true
log "install $BUILT_BIN → $TARGET_BIN"
if ! cp -f "$BUILT_BIN" "$TARGET_BIN.new" 2>>"$LOG"; then
    log "FATAL: cp to $TARGET_BIN.new failed"
    emit node_binary_refresh_failed "\"reason\":\"cp_failed\""
    exit 1
fi
chmod +x "$TARGET_BIN.new"
mv -f "$TARGET_BIN.new" "$TARGET_BIN"

NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
log "OK: $TARGET_BIN now at sha $NEW_SHA (origin/main = $MAIN_SHA)"
emit node_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
