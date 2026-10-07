#!/usr/bin/env bash
# install-queue-tender.sh — META-243
#
# Install the queue-tender loop as a launchd user agent (macOS). Idempotent.
#
# Usage:
#   bash scripts/setup/install-queue-tender.sh install
#   bash scripts/setup/install-queue-tender.sh uninstall
#   bash scripts/setup/install-queue-tender.sh status
#   bash scripts/setup/install-queue-tender.sh check     # exit 0 if installed (and loaded)
#
# Test/CI knobs:
#   CHUMP_QT_LAUNCH_AGENTS_DIR     override ~/Library/LaunchAgents
#   CHUMP_QT_LAUNCHCTL_DISABLED=1  skip launchctl calls (plist file only).
#                                  On a node without launchctl (CI/Linux) the
#                                  calls already no-op; this forces that path
#                                  for a macOS test harness.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABEL="com.chump.queue-tender"
TEMPLATE="$REPO_ROOT/scripts/launchd/$LABEL.plist"
AGENTS_DIR="${CHUMP_QT_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
INSTALLED="$AGENTS_DIR/$LABEL.plist"
LOOP="$REPO_ROOT/scripts/coord/queue-tender-loop.sh"
NO_LCTL="${CHUMP_QT_LAUNCHCTL_DISABLED:-0}"
DOMAIN="gui/$(id -u)"

_lctl() { [[ "$NO_LCTL" == "1" ]] && return 0; command -v launchctl >/dev/null 2>&1 || return 0; launchctl "$@"; }
_loaded() {
    [[ "$NO_LCTL" == "1" ]] && return 1
    command -v launchctl >/dev/null 2>&1 && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

case "${1:-}" in
    install|--install)
        [[ -f "$TEMPLATE" ]] || { echo "[install-queue-tender] ERROR: missing $TEMPLATE" >&2; exit 1; }
        [[ -f "$LOOP" ]] || { echo "[install-queue-tender] ERROR: missing $LOOP" >&2; exit 1; }
        chmod +x "$LOOP" 2>/dev/null || true
        mkdir -p "$AGENTS_DIR" "$HOME/.chump/logs"
        # Re-render, then (re)load so a second install converges instead of erroring.
        _loaded && _lctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
        sed -e "s#__REPO_ROOT__#$REPO_ROOT#g" -e "s#__HOME__#$HOME#g" "$TEMPLATE" > "$INSTALLED"
        _lctl bootstrap "$DOMAIN" "$INSTALLED" >/dev/null 2>&1
        _lctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1
        echo "[install-queue-tender] installed $INSTALLED"
        ;;
    uninstall|--uninstall)
        _loaded && _lctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
        if [[ -f "$INSTALLED" ]]; then rm -f "$INSTALLED"; echo "[install-queue-tender] removed $INSTALLED"
        else echo "[install-queue-tender] not installed — nothing to remove"; fi
        ;;
    status|--status)
        if [[ -f "$INSTALLED" ]]; then echo "[install-queue-tender] plist: installed ($INSTALLED)"
        else echo "[install-queue-tender] plist: not installed"; fi
        if _loaded; then echo "[install-queue-tender] launchd: LOADED"; else echo "[install-queue-tender] launchd: not loaded"; fi
        ;;
    check|--check)
        if [[ ! -f "$INSTALLED" ]]; then echo "[install-queue-tender] FAIL: not installed" >&2; exit 1; fi
        if [[ "$NO_LCTL" != "1" ]] && command -v launchctl >/dev/null 2>&1 && ! _loaded; then
            echo "[install-queue-tender] FAIL: installed but not loaded" >&2; exit 1
        fi
        echo "[install-queue-tender] OK"
        ;;
    *)
        echo "Usage: install-queue-tender.sh install|uninstall|status|check" >&2
        exit 1
        ;;
esac
