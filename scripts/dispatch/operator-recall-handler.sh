#!/usr/bin/env bash
# operator-recall-handler.sh — INFRA-665: notification delivery backend.
#
# Runs as a daemon listening on localhost:9998 for operator-recall POSTs.
# Routes notifications to the configured channel (terminal-notifier, Slack, Pushover).
#
# Reads config from ~/.chump/operator-recall.toml
#
# Usage:
#   operator-recall-handler.sh    # runs in foreground; send SIGTERM to stop
#   nohup operator-recall-handler.sh >~/.chump/operator-recall-handler.log 2>&1 &

set -uo pipefail

CONFIG_FILE="${HOME}/.chump/operator-recall.toml"
LISTEN_PORT=9998
LISTEN_ADDR="127.0.0.1"

_info()  { echo "[operator-recall-handler] $(date +%Y-%m-%dT%H:%M:%SZ) $*"; }
_error() { echo "[operator-recall-handler] $(date +%Y-%m-%dT%H:%M:%SZ) ERROR: $*" >&2; }

# ── Config parsing (simple TOML reader) ───────────────────────────────────────

_read_config() {
    # Parses ~/.chump/operator-recall.toml and exports channel vars.
    # Assumes format:
    #   [channel]
    #   type = "terminal-notifier"
    #   enabled = true
    #   [terminal-notifier]
    #   sound = "Glass"
    #   ... etc

    if [[ ! -f "$CONFIG_FILE" ]]; then
        _error "Config not found: $CONFIG_FILE"
        return 1
    fi

    # Extract [channel] type = "..."
    CHANNEL_TYPE=$(grep -A1 '^\[channel\]' "$CONFIG_FILE" | grep 'type =' | sed 's/.*type = "\([^"]*\)".*/\1/')
    CHANNEL_ENABLED=$(grep -A2 '^\[channel\]' "$CONFIG_FILE" | grep 'enabled =' | sed 's/.*enabled = \([^[:space:]]*\).*/\1/' | tr '[:upper:]' '[:lower:]')

    if [[ -z "$CHANNEL_TYPE" ]]; then
        CHANNEL_TYPE="terminal-notifier"
    fi
    if [[ -z "$CHANNEL_ENABLED" ]]; then
        CHANNEL_ENABLED="true"
    fi

    case "$CHANNEL_TYPE" in
        terminal-notifier)
            NOTIFY_SOUND=$(grep -A2 '^\[terminal-notifier\]' "$CONFIG_FILE" | grep 'sound =' | sed 's/.*sound = "\([^"]*\)".*/\1/')
            [[ -z "$NOTIFY_SOUND" ]] && NOTIFY_SOUND="Glass"
            ;;
        slack)
            SLACK_WEBHOOK=$(grep -A2 '^\[slack\]' "$CONFIG_FILE" | grep 'webhook_url =' | sed 's/.*webhook_url = "\([^"]*\)".*/\1/')
            ;;
        pushover)
            PUSHOVER_USER=$(grep -A3 '^\[pushover\]' "$CONFIG_FILE" | grep 'user_key =' | sed 's/.*user_key = "\([^"]*\)".*/\1/')
            PUSHOVER_TOKEN=$(grep -A3 '^\[pushover\]' "$CONFIG_FILE" | grep 'api_token =' | sed 's/.*api_token = "\([^"]*\)".*/\1/')
            ;;
    esac

    _info "Loaded config: channel=$CHANNEL_TYPE enabled=$CHANNEL_ENABLED"
}

# ── Notification handlers ──────────────────────────────────────────────────────

_notify_terminal_notifier() {
    local title="$1" message="$2"
    if ! command -v terminal-notifier >/dev/null 2>&1; then
        _error "terminal-notifier not found in PATH"
        return 1
    fi
    terminal-notifier -title "$title" -message "$message" -sound "${NOTIFY_SOUND:-Glass}" 2>/dev/null || \
        _error "terminal-notifier failed"
}

_notify_slack() {
    local condition="$1" reason="$2"
    if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
        _error "Slack webhook URL not configured"
        return 1
    fi
    local payload
    payload="$(printf '{"text":"🚨 Fleet Alert: %s\\n_%s_"}' "$condition" "$reason")"
    curl -sf -X POST -H "Content-Type: application/json" \
        -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 || \
        _error "Slack POST failed"
}

_notify_pushover() {
    local condition="$1" reason="$2"
    if [[ -z "${PUSHOVER_USER:-}" ]] || [[ -z "${PUSHOVER_TOKEN:-}" ]]; then
        _error "Pushover credentials not configured"
        return 1
    fi
    curl -sf -X POST https://api.pushover.net/1/messages.json \
        -F "token=${PUSHOVER_TOKEN}" \
        -F "user=${PUSHOVER_USER}" \
        -F "title=Fleet Alert: $condition" \
        -F "message=$reason" \
        -F "priority=2" >/dev/null 2>&1 || \
        _error "Pushover POST failed"
}

_send_notification() {
    local condition="$1" reason="$2"

    [[ "$CHANNEL_ENABLED" != "true" ]] && return 0

    _info "Sending notification: condition=$condition reason=$reason"

    case "$CHANNEL_TYPE" in
        terminal-notifier)
            _notify_terminal_notifier "CHUMP ALERT: $condition" "$reason"
            ;;
        slack)
            _notify_slack "$condition" "$reason"
            ;;
        pushover)
            _notify_pushover "$condition" "$reason"
            ;;
        *)
            _error "Unknown channel type: $CHANNEL_TYPE"
            return 1
            ;;
    esac
}

# ── HTTP server ───────────────────────────────────────────────────────────────

_run_server() {
    # Simple HTTP server listening on $LISTEN_ADDR:$LISTEN_PORT
    # Parses JSON body and routes to notification handler.
    # Uses socat (if available) or netcat; falls back to Python.

    if command -v socat >/dev/null 2>&1; then
        _run_server_socat
    elif command -v python3 >/dev/null 2>&1; then
        _run_server_python
    else
        _error "Neither socat nor python3 found; cannot start HTTP server"
        return 1
    fi
}

_run_server_socat() {
    _info "Starting HTTP server on $LISTEN_ADDR:$LISTEN_PORT (socat)"

    socat -v \
        TCP-LISTEN:$LISTEN_PORT,reuseaddr,fork \
        EXEC:"bash -c '_handle_request_socat'" &
    _server_pid=$!
}

_run_server_python() {
    _info "Starting HTTP server on $LISTEN_ADDR:$LISTEN_PORT (python3)"

    python3 - "$LISTEN_PORT" <<'PYEOF' &
import sys, json, socket, os
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

port = int(sys.argv[1])
config_file = os.path.expanduser("~/.chump/operator-recall.toml")

class RecallHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return

        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            data = json.loads(body)
        except Exception as e:
            self.send_response(400)
            self.end_headers()
            print(f"[operator-recall-handler] Error parsing request: {e}", file=sys.stderr)
            return

        condition = data.get("condition", "UNKNOWN")
        reason = data.get("reason", "no details")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True}).encode("utf-8"))

        # Dispatch notification asynchronously.
        def notify():
            # Read config and send notification based on channel type.
            try:
                with open(config_file, "r") as f:
                    content = f.read()

                channel_type = "terminal-notifier"
                for line in content.split("\n"):
                    if 'type = "' in line:
                        channel_type = line.split('"')[1]
                        break

                if channel_type == "terminal-notifier":
                    os.system(f'terminal-notifier -title "CHUMP ALERT: {condition}" -message "{reason}" 2>/dev/null')
                elif channel_type == "slack":
                    webhook = None
                    for line in content.split("\n"):
                        if 'webhook_url = "' in line:
                            webhook = line.split('"')[1]
                            break
                    if webhook:
                        import subprocess
                        payload = json.dumps({"text": f"🚨 Fleet Alert: {condition}\n_{reason}_"})
                        subprocess.run(["curl", "-sf", "-X", "POST", "-H", "Content-Type: application/json",
                                       "-d", payload, webhook], capture_output=True)
            except Exception as e:
                print(f"[operator-recall-handler] Notification failed: {e}", file=sys.stderr)

        Thread(target=notify, daemon=True).start()

    def log_message(self, format, *args):
        print(f"[operator-recall-handler] {format % args}")

try:
    server = HTTPServer(("127.0.0.1", port), RecallHandler)
    print(f"[operator-recall-handler] HTTP server listening on 127.0.0.1:{port}")
    server.serve_forever()
except Exception as e:
    print(f"[operator-recall-handler] ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    _server_pid=$!
}

# ── Signal handlers ───────────────────────────────────────────────────────────

_cleanup() {
    _info "Shutting down..."
    if [[ -n "${_server_pid:-}" ]] && kill -0 "$_server_pid" 2>/dev/null; then
        kill "$_server_pid" 2>/dev/null || true
    fi
    exit 0
}

trap _cleanup SIGTERM SIGINT

# ── Main ──────────────────────────────────────────────────────────────────────

_read_config || exit 1
_run_server

_info "Handler started successfully"
wait
