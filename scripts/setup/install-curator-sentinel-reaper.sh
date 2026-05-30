#!/usr/bin/env bash
# scripts/setup/install-curator-sentinel-reaper.sh — META-165
#
# Installs the curator-sentinel-reaper as a launchd agent (macOS) or
# cron job (Linux). Idempotent: safe to re-run.
#
# The reaper removes stale .chump-locks/.curator-opus-*.lock files whose
# PID is dead OR whose mtime is > 30 minutes old. Runs every 5 minutes.
#
# Usage:
#   bash scripts/setup/install-curator-sentinel-reaper.sh             # install
#   bash scripts/setup/install-curator-sentinel-reaper.sh --check     # exit 0 if loaded, 1 if not
#   bash scripts/setup/install-curator-sentinel-reaper.sh --uninstall # remove plist + unload

set -euo pipefail

LABEL="com.chump.curator-sentinel-reaper"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/curator-sentinel-reaper.sh"
PLIST_SRC="$REPO_ROOT/.chump/launchd/${LABEL}.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

log() { printf '[install-curator-sentinel-reaper] %s\n' "$*"; }

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
    if [[ "$(uname)" == "Darwin" ]] && is_loaded; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
        log "unloaded $LABEL"
    fi
    rm -f "$PLIST_DEST"
    log "removed $PLIST_DEST"
    exit 0
fi

# ── install ────────────────────────────────────────────────────────────────
[[ -f "$SCRIPT" ]] || { log "ERROR: reaper script not found at $SCRIPT"; exit 1; }
chmod +x "$SCRIPT"

if [[ "$(uname)" == "Darwin" ]]; then
    if [[ ! -f "$PLIST_SRC" ]]; then
        log "ERROR: plist not found at $PLIST_SRC"
        exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    # Substitute /path/to/Chump placeholder with actual repo path.
    sed "s|/path/to/Chump|$REPO_ROOT|g" "$PLIST_SRC" > "$PLIST_DEST"

    # Unload first if already loaded (idempotent re-install).
    if is_loaded; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
    fi
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || \
        launchctl load -w "$PLIST_DEST"

    if is_loaded; then
        log "SUCCESS — $LABEL loaded"
    else
        log "WARNING — load attempted but launchctl list does not show $LABEL yet"
    fi
else
    # Linux: cron every 5 min.
    CRON_LINE="*/5 * * * * $SCRIPT >> /tmp/chump-curator-sentinel-reaper.out.log 2>/tmp/chump-curator-sentinel-reaper.err.log"
    ( crontab -l 2>/dev/null | grep -v 'curator-sentinel-reaper'; echo "$CRON_LINE" ) | crontab -
    log "cron job installed (every 5 min)"
fi
