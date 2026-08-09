# helsinki tailnet-bind hardening (RESILIENT-251)

Defense-in-depth follow-through after the 2026-08-08 open-to-internet incident
(ufw default-deny + fail2ban + key-only ssh landed same-day). This closes the
second layer: don't let a firewall be the *only* thing standing between the
fleet's coordination services and the public internet.

## Final state (2026-08-09)

| Service | Bind | Boot-order | Verified |
|---|---|---|---|
| ollama (11434) | `100.101.188.30` (tailnet only) | `After=`/`Wants=tailscaled.service` drop-in | dark on public IP, embedder answers over tailnet (2026-08-08) |
| nats (4222, 7422 leafnodes) | `100.101.188.30` (tailnet only) | `After=`/`Wants=tailscaled.service` drop-in, proven by live `tailscaled` restart | dark on public IP, INFO banner + auth enforced over tailnet (2026-08-09) |
| rerank_server.py (8785) | retired | n/a | port closed; was never systemd-managed so it could not survive a reboot anyway |

## Why 8785 was retired instead of rebound

It served almanac's cross-encoder rerank, a feature almanac keeps **disabled
by default** after measuring it negative. Hardening a feature nothing uses is
wasted defense-in-depth; retiring it removes the attack surface entirely.
It was already firewalled and running as a bare foreground process in a pts
session (no crontab/unit/rc.local), so it would not have restarted after a
reboot regardless.

## NATS rebind blast-radius check

Before rebinding, confirmed no live consumer depended on the `0.0.0.0` bind:
`/root/.chump/providers.env`'s `CHUMP_NATS_URL` already pointed at a
tailnet-style IP (not `127.0.0.1`), the CI test scripts that touch NATS use
their own ephemeral ports (14222, 19999), and the canonical installer
(`scripts/setup/nats-broker-install.sh`) already defaults to a tailnet-only
bind — the `0.0.0.0` config on helsinki was drift from that intended design.
`ss -tnp` showed zero active connections at rebind time.

ufw's default-deny-in + tailscale0 allow-list is unchanged throughout; the
bind change is an additional layer, not a replacement for it.
