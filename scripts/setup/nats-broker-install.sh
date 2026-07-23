#!/usr/bin/env bash
# nats-broker-install.sh — stand up the shared NATS coordination broker on the
# fleet HUB (the always-on box). Nodes point CHUMP_NATS_URL at it so `chump claim`
# acquires a cluster-wide atomic KV claim and two machines never pick the same gap.
#
# Provenance: the closetjunky bringup (2026-07-23, RESILIENT-190/191). Captures the
# exact working recipe: JetStream KV, user:password auth, bound to the TAILNET
# interface only (never the public internet), systemd-managed, survives reboot.
#
# SECURITY: binds to the Tailscale IP by default. The auth secret is generated
# on-box (openssl rand), stored 0600, and NEVER printed. The broker URL (with the
# secret) is written to ~/.chump/providers.env; propagate it to nodes by streaming
# machine-to-machine (see the printed instructions), not by pasting it anywhere.
#
# Usage:
#   bash scripts/setup/nats-broker-install.sh                 # bind to tailnet IP (recommended)
#   CHUMP_NATS_BIND=0.0.0.0 bash ...                          # public bind (INSECURE — token only)
#   CHUMP_NATS_ROTATE=1 bash ...                              # rotate the secret (burns the old one)
set -euo pipefail

log() { printf '[nats-broker-install] %s\n' "$*"; }
die() { printf '[nats-broker-install] ERROR: %s\n' "$*" >&2; exit 1; }
_sudo() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

[[ "$(uname -s)" == "Linux" ]] || die "hub broker install is Linux-only (systemd)"

# ── 1. Resolve the bind address (tailnet by default) ───────────────────────
BIND="${CHUMP_NATS_BIND:-}"
if [[ -z "$BIND" ]]; then
  if command -v tailscale >/dev/null 2>&1; then
    BIND="$(tailscale ip -4 2>/dev/null | head -1)"
  fi
  [[ -n "$BIND" ]] || die "no Tailscale IP found. Run 'sudo tailscale up' first, or set CHUMP_NATS_BIND=0.0.0.0 to bind publicly (INSECURE)."
fi
if [[ "$BIND" == "0.0.0.0" ]]; then
  log "WARNING: binding to 0.0.0.0 exposes NATS to every network the host is on."
  log "WARNING: only the auth token protects it, and it travels UNENCRYPTED. Prefer a tailnet bind."
fi
log "bind address: $BIND:4222"

# ── 2. Install the nats-server binary (latest release) ─────────────────────
if ! command -v nats-server >/dev/null 2>&1; then
  LATEST="$(curl -sI https://github.com/nats-io/nats-server/releases/latest | awk -F'tag/' '/^location:/{print $2}' | tr -d '\r')"
  [[ -n "$LATEST" ]] || LATEST="v2.14.3"
  log "installing nats-server $LATEST"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -sL "https://github.com/nats-io/nats-server/releases/download/${LATEST}/nats-server-${LATEST}-linux-amd64.tar.gz" -o "$TMP/nats.tgz"
  tar xzf "$TMP/nats.tgz" -C "$TMP"
  _sudo install -m 0755 "$TMP/nats-server-${LATEST}-linux-amd64/nats-server" /usr/local/bin/nats-server
fi
log "nats-server: $(nats-server --version)"

# ── 3. Auth secret (generate once; rotate on request) ──────────────────────
_sudo mkdir -p /etc/nats /var/lib/nats
if [[ ! -f /etc/nats/token || "${CHUMP_NATS_ROTATE:-0}" == "1" ]]; then
  _sudo bash -c 'openssl rand -hex 32 > /etc/nats/token && chmod 600 /etc/nats/token'
  log "auth secret $( [[ -f /etc/nats/token ]] && echo generated || echo rotated ) (stored 0600, not printed)"
else
  log "auth secret already present (pass CHUMP_NATS_ROTATE=1 to rotate)"
fi

# ── 4. Broker config — JetStream + user:password, bound to $BIND ───────────
# user:password (not bare token) because async_nats parses userinfo unambiguously
# only in user:pass form (RESILIENT-190).
_sudo bash -c "cat > /etc/nats/nats.conf" <<CONF
listen: ${BIND}:4222
server_name: $(hostname)-chump
authorization { user: "chump", password: "$(_sudo cat /etc/nats/token)" }
jetstream {
  store_dir: /var/lib/nats
  max_memory_store: 256MB
  max_file_store: 2GB
}
CONF
_sudo chmod 600 /etc/nats/nats.conf

# ── 5. systemd unit (waits for tailscale, always restarts) ─────────────────
_sudo bash -c 'cat > /etc/systemd/system/nats.service' <<'UNIT'
[Unit]
Description=NATS Server (chump fleet coordination)
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/nats-server -c /etc/nats/nats.conf
Restart=always
RestartSec=2
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
_sudo systemctl daemon-reload
_sudo systemctl enable --now nats.service
sleep 2
[[ "$(_sudo systemctl is-active nats.service)" == "active" ]] || die "nats.service failed to start — check: journalctl -u nats.service"
log "nats.service active, listening on $(_sudo ss -ltnp 2>/dev/null | awk '/:4222/{print $4; exit}')"

# ── 6. Write the hub's own CHUMP_NATS_URL (never printed with the token) ────
ENV="$HOME/.chump/providers.env"
mkdir -p "$HOME/.chump"; touch "$ENV"; chmod 600 "$ENV"
URL="nats://chump:$(_sudo cat /etc/nats/token)@${BIND}:4222"
if grep -q '^CHUMP_NATS_URL=' "$ENV"; then
  # portable in-place edit (avoid GNU/BSD sed divergence): rewrite via grep+append
  { grep -v '^CHUMP_NATS_URL=' "$ENV"; printf 'CHUMP_NATS_URL=%s\n' "$URL"; } > "$ENV.new" && mv "$ENV.new" "$ENV"
else
  printf 'CHUMP_NATS_URL=%s\n' "$URL" >> "$ENV"
fi
chmod 600 "$ENV"

cat <<DONE

[nats-broker-install] DONE.
  Broker:   ${BIND}:4222  (JetStream KV + user:password auth)
  Hub env:  CHUMP_NATS_URL written to $ENV  (secret not shown)

  Propagate to a NODE without exposing the secret (stream machine-to-machine):

    ssh <hub> "grep '^CHUMP_NATS_URL=' ~/.chump/providers.env" \\
      | ssh <node> "cat >> ~/.chump/chumpd.env"

  On the node, also set CHUMP_NATS_TIMEOUT_MS=8000 if it reaches the hub over a
  high-latency (home-NAT / DERP-relayed) link. Then restart chumpd on both.
DONE
