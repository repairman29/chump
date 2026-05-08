#!/usr/bin/env bash
# install-operator-recall-channel.sh — INFRA-665: set up operator notification channel.
#
# Writes ~/.chump/operator-recall.toml and starts the notification handler.
# Supports three channels: (a) macOS terminal-notifier, (b) Slack webhook, (c) Pushover/email.
#
# Usage:
#   install-operator-recall-channel.sh [--channel {terminal-notifier|slack|pushover}] [--interactive]
#
# If --interactive, prompts for channel choice and config.
# Otherwise, auto-detects available channel: terminal-notifier > slack > pushover.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG_FILE="${HOME}/.chump/operator-recall.toml"
HANDLER_SCRIPT="$REPO_ROOT/scripts/dispatch/operator-recall-handler.sh"
HANDLER_PID_FILE="${HOME}/.chump/operator-recall-handler.pid"

_channel="${1:-}"
_interactive=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)      _channel="$2"; shift 2 ;;
        --interactive)  _interactive=1; shift ;;
        *)              echo "Usage: $0 [--channel {terminal-notifier|slack|pushover}] [--interactive]" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

_info()  { echo "[operator-recall-setup] $*"; }
_warn()  { echo "[operator-recall-setup] WARNING: $*" >&2; }
_error() { echo "[operator-recall-setup] ERROR: $*" >&2; exit 1; }

_detect_channel() {
    # Auto-detect the best available channel.
    if command -v terminal-notifier >/dev/null 2>&1; then
        echo "terminal-notifier"
    elif command -v curl >/dev/null 2>&1 && [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        echo "slack"
    else
        echo "terminal-notifier"  # default fallback
    fi
}

_write_config() {
    local channel="$1"
    mkdir -p "$(dirname "$CONFIG_FILE")"

    case "$channel" in
        terminal-notifier)
            cat > "$CONFIG_FILE" <<'TOML'
[channel]
type = "terminal-notifier"
enabled = true

[terminal-notifier]
sound = "Glass"
TOML
            _info "Wrote config for terminal-notifier to $CONFIG_FILE"
            ;;
        slack)
            _error "slack channel requires SLACK_WEBHOOK_URL env var; use --interactive to configure"
            ;;
        pushover)
            _error "pushover channel requires PUSHOVER_USER_KEY and PUSHOVER_API_TOKEN; use --interactive to configure"
            ;;
        *)
            _error "unknown channel: $channel"
            ;;
    esac
}

_start_handler() {
    # Kill any existing handler.
    if [[ -f "$HANDLER_PID_FILE" ]]; then
        local old_pid; old_pid="$(cat "$HANDLER_PID_FILE" 2>/dev/null)"
        if kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
            sleep 0.5
        fi
    fi

    # Start new handler in background.
    if [[ -x "$HANDLER_SCRIPT" ]]; then
        nohup "$HANDLER_SCRIPT" >"${HOME}/.chump/operator-recall-handler.log" 2>&1 &
        local new_pid=$!
        echo "$new_pid" > "$HANDLER_PID_FILE"
        _info "Started operator-recall-handler (PID=$new_pid)"
    else
        _warn "Handler script not found: $HANDLER_SCRIPT"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

if (( _interactive )); then
    echo "Operator Recall Channel Setup"
    echo "=============================="
    echo "Choose a notification channel:"
    echo "  1) terminal-notifier (macOS notifications)"
    echo "  2) Slack (requires webhook URL)"
    echo "  3) Pushover (requires user key + API token)"
    read -p "Enter choice (1-3, default=1): " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            _channel="terminal-notifier"
            ;;
        2)
            _channel="slack"
            read -p "Slack webhook URL: " webhook_url
            mkdir -p "$(dirname "$CONFIG_FILE")"
            cat > "$CONFIG_FILE" <<TOML
[channel]
type = "slack"
enabled = true

[slack]
webhook_url = "$webhook_url"
TOML
            _info "Wrote Slack config to $CONFIG_FILE"
            ;;
        3)
            _channel="pushover"
            read -p "Pushover user key: " user_key
            read -p "Pushover API token: " api_token
            mkdir -p "$(dirname "$CONFIG_FILE")"
            cat > "$CONFIG_FILE" <<TOML
[channel]
type = "pushover"
enabled = true

[pushover]
user_key = "$user_key"
api_token = "$api_token"
TOML
            _info "Wrote Pushover config to $CONFIG_FILE"
            ;;
        *)
            _error "Invalid choice: $choice"
            ;;
    esac
else
    # Non-interactive: auto-detect or use provided channel.
    if [[ -z "$_channel" ]]; then
        _channel="$(_detect_channel)"
        _info "Auto-detected channel: $_channel"
    fi
    _write_config "$_channel"
fi

_start_handler

# Export env var for operator-recall.sh to find the handler.
export CHUMP_OPERATOR_RECALL_URL="http://127.0.0.1:9998"

_info "Setup complete. Operator recall notifications are enabled."
_info "Config: $CONFIG_FILE"
_info "Handler PID: $(cat "$HANDLER_PID_FILE" 2>/dev/null || echo 'unknown')"
