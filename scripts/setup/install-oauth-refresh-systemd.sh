#!/usr/bin/env bash
# install-oauth-refresh-systemd.sh — RESILIENT-410 (AC-C)
#
# Linux counterpart to install-oauth-refresh-launchd.sh. Installs a systemd
# *user* timer that runs oauth-token-refresh.sh every 5 min to keep
# ~/.chump/oauth-token.json fresh from CLAUDE_CODE_OAUTH_TOKEN (a long-lived
# `claude setup-token` OAuth token in ~/.chump/providers.env), so the farmer
# stays GREEN and headless `claude -p` workers re-read a fresh token — with NO
# dependency on the macOS keychain refresher. Fully decouples a Linux node
# (e.g. CJ) from the Mac for OAuth freshness.
#
# Requires: `loginctl enable-linger $USER` (so user timers run without a login
# session). Verify: systemctl --user list-timers | grep chump-oauth-refresh
#
# Uninstall:
#   systemctl --user disable --now chump-oauth-refresh.timer
#   rm ~/.config/systemd/user/chump-oauth-refresh.{service,timer}
#   systemctl --user daemon-reload
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INTERVAL="${CHUMP_OAUTH_REFRESH_INTERVAL:-300}"
REFRESH_SH="$REPO_ROOT/scripts/coord/oauth-token-refresh.sh"
UNIT_DIR="$HOME/.config/systemd/user"

[[ -f "$REFRESH_SH" ]] || { echo "ERROR: refresher not found at $REFRESH_SH" >&2; exit 1; }
mkdir -p "$UNIT_DIR"

# PATH includes cargo/local bins so `claude` is resolvable for the (rare, only
# on token change) validation call; missing claude just skips validation.
_PATH="$HOME/.local/bin:$HOME/.cargo/bin:$REPO_ROOT/target/release:/usr/local/bin:/usr/bin:/bin"

cat >"$UNIT_DIR/chump-oauth-refresh.service" <<EOF
[Unit]
Description=chump OAuth token freshness (Linux) — keep ~/.chump/oauth-token.json fresh (RESILIENT-410 AC-C)
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=%h
Environment=CHUMP_PROVIDERS_ENV=%h/.chump/providers.env
Environment=PATH=$_PATH
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $REFRESH_SH refresh-once
EOF

cat >"$UNIT_DIR/chump-oauth-refresh.timer" <<EOF
[Unit]
Description=chump OAuth token freshness timer (every ${INTERVAL}s) — RESILIENT-410 AC-C

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now chump-oauth-refresh.timer
systemctl --user start chump-oauth-refresh.service || true

echo "Installed chump-oauth-refresh.{service,timer} (interval=${INTERVAL}s)"
echo "  refresher: $REFRESH_SH refresh-once"
systemctl --user is-active chump-oauth-refresh.timer && echo "timer: active"
systemctl --user is-enabled chump-oauth-refresh.timer && echo "timer: enabled"
