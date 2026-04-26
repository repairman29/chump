#!/usr/bin/env bash
# WP-5.1: Print websocat commands for a minimal Mac↔client WebSocket echo spike.
# Requires: https://github.com/vi/websocat on PATH. See docs/operations/FLEET_WS_SPIKE_RUNBOOK.md
set -euo pipefail
if ! command -v websocat >/dev/null 2>&1; then
  echo "websocat not found. Install: brew install websocat (Mac) or pkg install websocat (Termux)."
  echo "In-tree Rust client (from repo root; same line-oriented protocol):"
  echo "  cargo run --release --bin fleet-ws-echo -- ws://127.0.0.1:18766"
  echo "Docs: docs/operations/FLEET_WS_SPIKE_RUNBOOK.md"
  exit 1
fi
echo "Mac (listener, echo):"
echo "  websocat -E ws-l:127.0.0.1:18766 mirror:"
echo ""
echo "Client (replace with Mac Tailscale IP):"
echo "  websocat ws://100.x.y.z:18766"
echo ""
echo "Alternative client (Rust, from repo root):"
echo "  cargo run --release --bin fleet-ws-echo -- ws://100.x.y.z:18766"
exit 0
