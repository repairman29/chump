#!/usr/bin/env bash
# scripts/setup/install-curator-supervisor.sh — INFRA-2239
#
# Install (or uninstall) the com.chump.curator-supervisor launchd user agent.
# Modeled on install-fleet-server.sh (INFRA-2175).
#
# Usage:
#   bash scripts/setup/install-curator-supervisor.sh             # install
#   bash scripts/setup/install-curator-supervisor.sh --check     # exit 0 if loaded, 1 if not
#   bash scripts/setup/install-curator-supervisor.sh --uninstall # remove plist + unload

set -euo pipefail

LABEL="com.chump.curator-supervisor"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo /Users/jeffadkins/Projects/Chump)}"
LOG_DIR="$HOME/Library/Logs/Chump"
PLIST_TEMPLATE="$REPO_ROOT/scripts/setup/launchd/${LABEL}.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN_PATH="$HOME/.cargo/bin/chump-curator-supervisor"

# Fallback: check common cargo output dirs.
if [[ ! -f "$BIN_PATH" ]]; then
    CANDIDATE="$REPO_ROOT/target/release/chump-curator-supervisor"
    if [[ -f "$CANDIDATE" ]]; then
        BIN_PATH="$CANDIDATE"
    fi
fi

log() { printf '[install-curator-supervisor] %s\n' "$*"; }

is_loaded() {
    launchctl list 2>/dev/null | grep -qE "^[0-9-]+\s+[0-9-]+\s+${LABEL}$"
}

# ── --check ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    if is_loaded; then
        log "LOADED — $LABEL is running"
        exit 0
    else
        log "NOT LOADED — $LABEL is not running"
        exit 1
    fi
fi

# ── --uninstall ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    if is_loaded; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
        log "unloaded $LABEL"
    fi
    rm -f "$PLIST_DEST"
    log "removed $PLIST_DEST"
    exit 0
fi

# ── install ────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    log "ERROR: plist template not found at $PLIST_TEMPLATE"
    exit 1
fi

if [[ ! -f "$BIN_PATH" ]]; then
    log "Binary not found at $BIN_PATH — building..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --release -p chump-curator-supervisor)
    BIN_PATH="$REPO_ROOT/target/release/chump-curator-supervisor"
fi

# Substitute placeholders.
sed \
    -e "s|CHUMP_CURATOR_SUPERVISOR_BIN_PLACEHOLDER|${BIN_PATH}|g" \
    -e "s|CHUMP_REPO_ROOT_PLACEHOLDER|${REPO_ROOT}|g" \
    -e "s|CHUMP_LOG_DIR_PLACEHOLDER|${LOG_DIR}|g" \
    "$PLIST_TEMPLATE" > "$PLIST_DEST"

log "wrote $PLIST_DEST"

# Unload first if already loaded (idempotent re-install).
if is_loaded; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
    sleep 1
fi

launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || \
    launchctl load "$PLIST_DEST"

if is_loaded; then
    log "SUCCESS — $LABEL loaded and running"
else
    log "WARNING — load attempted but launchctl list does not show $LABEL yet"
fi
