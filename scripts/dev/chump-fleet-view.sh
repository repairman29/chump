#!/usr/bin/env bash
# chump-fleet-view.sh — INFRA-2176
#
# Open the Fleet Scrubber UI in the default browser.
# The page is served by chump-fleet-server (INFRA-2175) at /scrubber.
#
# Usage:
#   bash scripts/dev/chump-fleet-view.sh [--fixtures]
#
# Options:
#   --fixtures   Open with ?fixtures=1 query param (dev/demo mode, no server needed)
#
# Note for INFRA-2175 author:
#   The server must mount a static-file route at /scrubber/* serving from
#   web/fleet-scrubber/ so this URL resolves correctly.

set -euo pipefail

URL="http://localhost:7070/scrubber"

if [[ "${1:-}" == "--fixtures" ]]; then
    # For dev without the server: serve locally via python3 and open with fixtures param.
    # Find a free port.
    PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    WEB_DIR="$REPO_ROOT/web/fleet-scrubber"

    if [[ ! -d "$WEB_DIR" ]]; then
        echo "error: web/fleet-scrubber/ not found at $WEB_DIR" >&2
        exit 1
    fi

    # Start server in background, kill on exit
    python3 -m http.server --directory "$WEB_DIR" "$PORT" &
    SERVER_PID=$!
    trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

    # Give server a moment to start
    sleep 0.3

    URL="http://localhost:$PORT/index.html?fixtures=1"
    echo "Serving fixture mode at $URL (pid=$SERVER_PID)"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    open "$URL"
elif command -v xdg-open &>/dev/null; then
    xdg-open "$URL"
elif command -v gnome-open &>/dev/null; then
    gnome-open "$URL"
else
    echo "Fleet Scrubber: $URL"
    echo "(No browser opener found; open the URL manually)"
fi

# If --fixtures mode: wait for Ctrl+C so the server stays alive
if [[ "${1:-}" == "--fixtures" ]]; then
    echo "Press Ctrl+C to stop the local server."
    wait $SERVER_PID 2>/dev/null || true
fi
