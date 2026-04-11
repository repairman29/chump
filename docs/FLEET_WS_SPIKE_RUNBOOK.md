# Fleet WebSocket spike runbook (WP-5.1)

**Goal:** Time-boxed **outbound** signaling from a **client** (e.g. Pixel Termux) to a **listener** on the Mac over **Tailscale**, without replacing SSH on day one. See [FLEET_ROLES.md](FLEET_ROLES.md) §Fleet transport spike.

**Not production messaging infrastructure** — demo and latency check only.

## Prerequisites

- **Tailscale** on Mac and Pixel; note the Mac’s **100.x** address.
- **[websocat](https://github.com/vi/websocat)** on both ends (`brew install websocat` on Mac; Termux: `pkg install websocat` or build from source).

## Mac (listener)

Bind only on Tailscale interface or `127.0.0.1` for lab safety:

```bash
# Echo: client sends text, server echoes (mirror)
websocat -E ws-l:127.0.0.1:18766 mirror:
```

To accept from Tailscale only, prefer **firewall rules** or bind to the Tailscale IP:

```bash
websocat -E ws-l:100.x.y.z:18766 mirror:
```

## Pixel / client

```bash
websocat ws://100.x.y.z:18766
```

Type a line; you should see the same line echoed.

## Automation helper

From repo root:

```bash
./scripts/fleet-ws-spike.sh
```

Prints the recommended `websocat` commands if the binary is on `PATH`; exits `0` if found.

## Rust client (in-tree)

Same protocol as the Pixel `websocat` client — outbound text frames, line-oriented:

```bash
cargo run --release --bin fleet-ws-echo -- ws://127.0.0.1:18766
```

Type a line and press Enter; the echo server should print the same line back. Useful when `websocat` is not installed on a dev machine.

## Non-goals

- No auth in this spike — use Tailscale ACLs + bind addresses.  
- **`fleet-ws-echo`** is a standalone lab binary, not the main `chump` process; a future WP could ingest WS messages in `web_server` or a sidecar.

## See also

- [NETWORK_SWAP.md](NETWORK_SWAP.md) — update IPs after network changes.  
- [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Mabel patrol context.
