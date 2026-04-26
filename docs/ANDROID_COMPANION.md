---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Android Companion App (Mabel / Pixel)

Mabel runs on a Google Pixel phone (Android) as the fleet's Sentinel node. This doc covers how Mabel communicates with the Mac (Chump), its role in mutual supervision, and the current integration surface.

## Roles

| Role | Description |
|------|-------------|
| **Sentinel** | 24/7 ops — deal/finance/GitHub/news watchers, uptime monitoring, calendar reminders |
| **Fleet monitor** | Probes Mac's Chump web API; triggers restart via SSH when Mac is down |
| **Research node** | Runs research heartbeat rounds when the Mac is sleeping or busy |
| **ADB automation** | Drives Android UI automation via ADB for mobile testing scenarios |

## How Mabel communicates with the Mac

**Current: inbound SSH from Mac**

The Mac can SSH into Mabel's Termux environment to restart the Discord bot:

```bash
scripts/restart-mabel.sh             # from Mac
# Uses PIXEL_SSH_HOST (default: termux), PIXEL_SSH_PORT (default: 8022)
# Also supports ADB-over-USB (auto-detected)
```

**Current: outbound health probe from Pixel**

Mabel probes the Mac's Chump web API:

```bash
# From Termux on Pixel:
MAC_TAILSCALE_IP=100.x.y.z MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=token \
    ~/chump/scripts/probe-mac-health.sh
```

Returns exit 0 on HTTP 200 (healthy), exit 1 on failure. Used by `mabel-farmer.sh` when `MAC_WEB_PORT` is set.

**Transport spike (planned):** An outbound WebSocket or MQTT channel from Pixel → Mac over Tailscale, so the phone can push status and task hints without the Mac exposing SSH. See [FLEET_ROLES.md](FLEET_ROLES.md#fleet-transport-spike-design) for the spike design.

## Running Mabel

Mabel runs in Termux on the Pixel. The bot process is `chump --discord` with Mabel-specific env vars:

```bash
# Termux on Pixel
CHUMP_MABEL=1 ./run-discord.sh          # or scripts/ensure-mabel-bot-up.sh
```

Key env vars:
- `CHUMP_MABEL=1` — selects Mabel's Discord bot token and identity
- `MAC_WEB_PORT` — when set, `mabel-farmer.sh` probes the Mac health endpoint each patrol round
- `PIXEL_SSH_HOST` / `PIXEL_SSH_PORT` — used by Mac-side scripts for SSH restart

## Mutual supervision (FLEET-001)

Mac and Pixel supervise each other:

| Direction | Script | What it does |
|-----------|--------|-------------|
| Mac → Pixel | `scripts/restart-mabel.sh` | SSH into Termux, stops old bot, starts new one, polls until up |
| Pixel → Mac | `scripts/probe-mac-health.sh` | GETs `/api/dashboard`, returns fleet status |

Full integration test: see [FLEET_ROLES.md](FLEET_ROLES.md#mutual-supervision-fleet-001).

## PWA as primary UI

The iPhone (Scout) uses the Chump Web PWA as its primary interface — it's not a headless agent. Mabel (Pixel) is the headless fleet node; the iPhone is the human interface over Tailscale.

## Limitations

- Mabel on Termux is resource-constrained — avoid large model loads on the phone
- ADB automation requires USB connection or network ADB (not always available)
- The WebSocket push channel from Pixel → Mac is not yet implemented

## See Also

- [Fleet Roles](FLEET_ROLES.md)
- [Inference Profiles](INFERENCE_PROFILES.md)
- [Operations](OPERATIONS.md)
