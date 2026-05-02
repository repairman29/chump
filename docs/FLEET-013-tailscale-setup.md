---
doc_tag: runbook
owner_gap: FLEET-013
last_audited: 2026-05-02
---

# FLEET-013 — Tailscale + agent discovery setup

**Status:** v0 shipped 2026-05-02 (FLEET-013).
**Scope:** L1 operationalization — make the FLEET-006 NATS ambient stream and FLEET-007 distributed leases reachable across physical machines without exposing NATS to the public internet.

---

## What this is

Distributed Chump agents need to talk to each other (NATS ambient stream, NATS-backed leases, FLEET-008 work board). Three constraints:

1. **NATS broker can't be internet-exposed** — it has no auth by default.
2. **Agents shouldn't need static IPs or VPN configs** — fleet machines come and go.
3. **Discovery should survive broker moves** — moving NATS to a different machine shouldn't require config edits everywhere.

Tailscale gives us all three: zero-config encrypted mesh VPN, MagicDNS for stable hostnames, no static IPs needed. The chump NATS broker runs on the tailnet; agents on any tailnet device can reach it via `<broker-hostname>.<tailnet>.ts.net:4222`.

---

## One-time setup per machine

```bash
bash scripts/setup/install-tailscale.sh
```

What it does (idempotent — safe to re-run):

1. `brew install tailscale` if not already installed
2. `sudo tailscale up` (interactive auth URL on first run; pre-auth via `TS_AUTHKEY` env for unattended)
3. Discover the NATS broker (priority order):
   - `$CHUMP_NATS_BROKER_HOST` (explicit override — canonical for fleet-launcher)
   - Probe each tailnet peer on `:4222` via `/dev/tcp` — first responder wins
   - Fall back to `127.0.0.1`
4. Write `CHUMP_NATS_URL=nats://<host>:4222` to `~/.chump/env`

Source the result in your shell rc so all subsequent agents pick it up:

```bash
echo '[ -f ~/.chump/env ] && source ~/.chump/env' >> ~/.zshrc
source ~/.zshrc
```

---

## NATS broker host

One machine in the fleet runs `nats-server` on port 4222. Convention: name it `chump-nats` in Tailscale so MagicDNS resolves `chump-nats.<tailnet>.ts.net`. Pin discovery via:

```bash
export CHUMP_NATS_BROKER_HOST="chump-nats.<tailnet>.ts.net"
```

Re-run `install-tailscale.sh` after setting that env to update `~/.chump/env`.

To **move the broker** to a different machine: rename the new machine to `chump-nats`, restart `nats-server` there, re-run `install-tailscale.sh` on each agent. No code or config changes needed.

---

## Auth key sharing (unattended fleet bootstrap)

For fleet-launcher / Mabel / CI workflows that bring up agents without interactive auth:

1. **Generate an ephemeral, reusable auth key** in the Tailscale admin: https://login.tailscale.com/admin/settings/keys
2. Store in `1Password` / your secret manager as `TS_AUTHKEY`
3. Pass to install script:

```bash
TS_AUTHKEY=tskey-auth-... bash scripts/setup/install-tailscale.sh
```

**Tighten the key** with tags so an exposed key can't add admin nodes:
- Tag: `tag:chump-fleet-agent`
- ACL allows the tag to talk to the NATS broker tag only

Example ACL fragment (`https://login.tailscale.com/admin/acls`):

```jsonc
{
  "tagOwners": {
    "tag:chump-fleet-agent": ["autogroup:admin"],
    "tag:chump-nats-broker": ["autogroup:admin"],
  },
  "acls": [
    { "action": "accept", "src": ["tag:chump-fleet-agent"], "dst": ["tag:chump-nats-broker:4222"] },
    { "action": "accept", "src": ["tag:chump-nats-broker"],  "dst": ["tag:chump-fleet-agent:*"]   },
  ],
}
```

---

## Exit-node config

Most chump agents do not need an exit node — they reach the public internet via their host's normal path. If a fleet machine is behind a strict NAT and the NATS broker can't reach it for ambient-stream pull, advertise the broker host as an exit node:

```bash
# On the broker:
sudo tailscale up --advertise-exit-node
# Then admin-approve the exit node at https://login.tailscale.com/admin/machines

# On the firewalled agent:
sudo tailscale up --exit-node=chump-nats
```

This is rare — try the default first.

---

## Verification

After install:

```bash
source ~/.chump/env
echo "$CHUMP_NATS_URL"      # should be nats://<host>:4222

# TCP reachability (bash builtin — no nc needed):
host="${CHUMP_NATS_URL#nats://}"; host="${host%:*}"
(echo > /dev/tcp/$host/4222) && echo "OK"

# End-to-end via chump-coord:
chump-coord ping
```

Two agents on different machines should see each other's events:

```bash
# On machine A:
chump-coord watch &
# On machine B (after install-tailscale.sh):
scripts/dev/ambient-emit.sh test-event "kind=fleet-013-smoke" "note=hello from B"
# Within ~1s, machine A should print the event in its watch loop.
```

---

## Troubleshooting

**`tailscale up` hangs on the auth URL**
- First-time auth always needs interactive browser. Use `TS_AUTHKEY` for headless.

**`install-tailscale.sh` finds no broker, falls back to 127.0.0.1**
- The broker isn't running on any tailnet peer, OR `:4222` is firewalled.
- Confirm the broker machine: `tailscale status` should list it as a peer.
- On the broker: `lsof -i :4222` should show `nats-server`.
- Manual override: `CHUMP_NATS_BROKER_HOST=<host> bash scripts/setup/install-tailscale.sh`

**Broker moved; agents still talking to old host**
- Re-run `install-tailscale.sh` on each agent (it overwrites `~/.chump/env`).
- A future enhancement (FLEET-013 v1) could push broker-move events through the existing ambient stream so this auto-corrects.

**Two agents on the same physical machine, only one can reach NATS**
- Tailscale is per-machine, not per-process. If the broker is on `127.0.0.1` for one process, all processes on that machine should also use `127.0.0.1`. The `install-tailscale.sh` discovery prefers tailnet peers, so on the broker host it will report the broker's tailnet IP — which may not be reachable to the broker itself if the loopback path was firewalled. If you hit this: explicitly set `CHUMP_NATS_BROKER_HOST=127.0.0.1` on the broker machine.

---

## Future work

- **FLEET-013 v1:** broker-move auto-recovery. Listen on ambient for a `broker_moved` event; rewrite `~/.chump/env` and prompt re-source.
- **FLEET-013 v2:** Tailscale device-tag-based authorization in `nats-server` config (drop the implicit-trust model where any tailnet device can reach the broker).
