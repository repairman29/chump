# Roadmap: Mabel Driver

Mabel's evolution path from fleet-monitor-on-Pixel to the full Sentinel role described in [FLEET_ROLES.md](FLEET_ROLES.md). Current state and what's needed.

## Current state (2026-04-19)

Mabel runs on Pixel 7a (Termux, Rust binary compiled for aarch64-linux-android). Current capabilities:

- **Heartbeat** — `scripts/heartbeat-mabel.sh` runs on cron; research and watch rounds
- **Fleet monitor** — Hourly Discord report (`scripts/hourly-update-to-discord.sh`)
- **SSH patrol** — Inbound SSH to Mac for health checks and restart operations
- **Mutual supervision** — Chump monitors Mabel liveness; Mabel monitors Chump liveness (`FLEET-001`)
- **ADB automation** — `scripts/adb-connect.sh`, device-local screen capture

## Phase 1 — Watch rounds (now / Q2 2026)

| Round | Script | Status | Description |
|-------|--------|--------|-------------|
| `deal_watch` | `heartbeat-mabel.sh --round deal_watch` | Pending | Monitor deal flow watchlist in brain/watch/ |
| `finance_watch` | `heartbeat-mabel.sh --round finance_watch` | Pending | Portfolio + spending summaries |
| `github_watch` | `heartbeat-mabel.sh --round github_watch` | Partial | `gh issue list` triage already done; needs scheduling |
| `news_brief` | `heartbeat-mabel.sh --round news_brief` | Pending | Morning news digest via `web_search` + brain |

**Requires:** `chump-brain/watch/` layout populated (see [CHUMP_BRAIN.md](CHUMP_BRAIN.md)).

## Phase 2 — Outbound push channel (Q3 2026)

**Problem:** Mac↔Pixel coordination today uses inbound SSH (Mabel reaches into Mac). Fails on strict networks and sleeping Macs.

**Solution:** Outbound WebSocket or MQTT from Pixel → Mac over Tailscale. Mabel pushes status + task hints; Mac runs a small sidecar listener.

**Mac behavior when Mabel is stale:** If last-seen exceeds threshold:
1. Log reason once
2. Notify owner via Discord DM
3. Pause sentinel-delegated repair (don't loop on broken SSH path)
4. Resume when Mabel heartbeat returns

**Gate:** `CHUMP_MABEL_OUTBOUND_PUSH=1` + Tailscale connectivity + shared auth token.

## Phase 3 — Morning briefing

Mabel synthesis round at ~07:00 local:
1. Pull brain/watch/ updates from Phase 1 rounds
2. Pull Chump's latest COS weekly snapshot
3. Synthesize → `logs/morning-brief-YYYY-MM-DD.md`
4. POST to `/api/briefing` on Mac → push notification to Scout (iOS)

## Phase 4 — Scout interface (iOS)

Scout (iPhone) as the primary user interface:
- iOS Shortcuts calling `/api/chat` + `/api/briefing`
- Voice → Shortcuts → Chump Web
- Quick capture → `brain/capture/` via Shortcuts + web API
- Mabel push notifications arrive via VAPID push

See [FLEET_ROLES.md](FLEET_ROLES.md) §Scout.

## Key env vars for Mabel

| Var | Description |
|-----|-------------|
| `CHUMP_FLEET_REPORT_ROLE` | `notify_only` disables hourly Discord report (use during stable periods) |
| `CHUMP_MABEL=1` | Start web server in Mabel mode (uses Mabel system prompt) |
| `CHUMP_MABEL_OUTBOUND_PUSH` | `1` = enable outbound WebSocket push to Mac (Phase 2) |
| `MABEL_MAC_WS_URL` | Mac listener URL for outbound push |

## Related scripts

| Script | Description |
|--------|-------------|
| `heartbeat-mabel.sh` | Main Mabel heartbeat (all rounds) |
| `restart-mabel-bot-on-pixel.sh` | ADB restart of Mabel process |
| `diagnose-mabel-model.sh` | Check inference model health on Pixel |
| `ensure-mabel-bot-up.sh` | Keep-alive check; restarts if down |
| `apply-mabel-badass-env.sh` | Apply the "badass" env profile for high-capacity runs |

## See Also

- [FLEET_ROLES.md](FLEET_ROLES.md) — Three-role architecture (Forge/Sentinel/Interface)
- [ANDROID_COMPANION.md](ANDROID_COMPANION.md) — Mabel setup, SSH scripts, ADB
- [INFERENCE_MESH.md](INFERENCE_MESH.md) — Pixel inference tier (1B/3B models)
- [OPERATIONS.md](OPERATIONS.md) — Mabel and Pixel sections
