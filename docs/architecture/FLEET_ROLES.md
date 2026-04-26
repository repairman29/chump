---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Fleet Roles — Chump + Mabel + Scout

Summary of the Fleet Roles proposal: turning the agent fleet from "agents that build agents" into a **personal operations team** that does real work. Full proposal text: [PROPOSAL_FLEET_ROLES.md](PROPOSAL_FLEET_ROLES.md).

## The three roles

| Node | Current | Proposed |
|------|---------|----------|
| **Chump (Mac)** | Self-improvement coding agent | **Forge:** builder, analyst, researcher, code reviewer, data cruncher; `CHUMP_REPO` can point at other projects. |
| **Mabel (Pixel)** | Fleet monitor + research | **Sentinel:** 24/7 ops, deal/finance/GitHub/news watchers, uptime, calendar reminders, ADB automation. |
| **Scout (iPhone)** | Inferrlm mesh node, barely used | **Interface:** you + iOS Shortcuts + Chump Web PWA (chat, quick capture, briefings, Shortcut triggers). No headless agent on device. |

Cross-cutting: **shared brain** (`research/`, `watch/`, `capture/`, `projects/`, `reports/`), **task assignee** (chump | mabel | jeff | any), **Chump Web API** (ingest, briefing, research, watch, projects), **notify** routing (push vs Discord vs silent).

## Implementation priority (from proposal)

| # | What | Effort | Depends on | Unlocks |
|---|------|--------|------------|---------|
| 1 | Chump Web PWA (full Tier 2 spec) | 12 d | Nothing | Everything below |
| 2 | Research pipeline (Chump round + brain storage) | 2 d | #1 (for triggering/viewing) | Briefs, competitive analysis, learning |
| 3 | Brain watchlists + Mabel watch rounds (deals, finance, github) | 2 d | Nothing | Passive monitoring |
| 4 | Morning briefing (Mabel synthesis round) | 1 d | #1 (for push), #3 | Daily value delivery |
| 5 | Quick capture (iPhone → Chump Web → brain) | 1 d | #1 | Personal knowledge base |
| 6 | External project work (Chump multi-repo) | 1 d | Nothing | Chump does real work for you |
| 7 | iOS Shortcuts (deploy, status, create task, capture) | 0.5 d each | #1 | Voice-driven fleet control |
| 8 | Task routing with assignee | 1 d | Nothing | Multi-agent coordination |
| 9 | Calendar integration | 2 d | #1 | Smart reminders |
| 10 | Learning assistant | 1 d | #2 | Skill development |

**Critical path:** Chump Web PWA is the gateway; everything else layers on top. See [CHUMP_BRAIN.md](CHUMP_BRAIN.md) for the expanded brain layout (`research/`, `watch/`, `capture/`, `projects/`, `reports/`).

## Fleet transport spike (design)

**Problem:** Today much of Mac↔Pixel coordination is **inbound SSH** (Mabel patrol reaches into the Mac). That fits a home lab but is awkward for strict networks, sleeping Macs, and “who initiates?” clarity.

**Spike direction (time-boxed prototype, optional):** Add an **outbound** channel from the **Pixel (Mabel)** to the **Mac** over **Tailscale** — e.g. **WebSocket** or **MQTT** — so the phone can push status, task hints, or “wake work” signals without the Mac exposing SSH to the internet. The Mac would run a small listener (sidecar or Chump web extension) authenticated via Tailscale identity or a shared secret.

**Mac behavior when sentinel is stale:** When the Mac has **not** heard from Mabel (or last-seen exceeds a threshold), treat **sentinel-delegated repair** as **paused or degraded** — log a single clear reason, **notify** once, and **do not** loop forever on SSH-based fixes that assume the Pixel path is live. Detailed scheduling lives with Mabel patrol / heartbeat scripts; this doc captures the **contract**: outbound liveness complements inbound SSH.

**Non-goals for the spike:** Replacing SSH entirely on day one; multi-tenant broker in the cloud. See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) for the same note in the Mabel roadmap.

**Concrete spike steps:** [FLEET_WS_SPIKE_RUNBOOK.md](FLEET_WS_SPIKE_RUNBOOK.md) and `./scripts/fleet-ws-spike.sh` (requires `websocat` on PATH).

## Mutual supervision (FLEET-001)

Mac and Pixel supervise each other. Both directions are implemented:

### Mac → Pixel: restart Mabel

```bash
# From Mac — SSH restart the Mabel Discord bot on the Pixel
scripts/restart-mabel.sh
```

Env: `PIXEL_SSH_HOST` (default: `termux`), `PIXEL_SSH_PORT` (default: `8022`).
Supports ADB-over-USB (auto-detected) and Tailscale/WiFi (`PIXEL_SSH_FORCE_NETWORK=1`).
Retries up to `RESTART_MABEL_MAX_ATTEMPTS` (default: 3) and verifies the bot is running.
Full implementation: `scripts/restart-mabel-bot-on-pixel.sh`.

### Pixel → Mac: health probe

```bash
# From Pixel (Termux) — probe Mac's Chump web API
MAC_TAILSCALE_IP=100.x.y.z MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=token scripts/probe-mac-health.sh
```

Returns exit 0 on HTTP 200, exit 1 on failure. `--json` flag prints the dashboard JSON.
`mabel-farmer.sh` calls this automatically when `MAC_WEB_PORT` is set.

### Integration test

Verify both directions with the fleet running:

```bash
# 1. Mac heartbeat up — check Pixel can reach Mac dashboard
ssh termux 'MAC_TAILSCALE_IP=100.x.y.z MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=token \
    ~/chump/scripts/probe-mac-health.sh'
# Expected: probe-mac-health: OK — Mac /api/dashboard responded 200

# 2. Mabel bot up — check Mac can SSH-restart it
scripts/restart-mabel.sh
# Expected: "Mabel bot started." + "Done."

# 3. Full fleet health including both sides
scripts/fleet-health.sh
# Expected: all checks pass
```

## Relation to existing roadmaps

- **Chump:** [ROADMAP.md](ROADMAP.md) — Fleet expansion (external work, research rounds, review round) is the next horizon after current unchecked items.
- **Mabel:** [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Extends with watch rounds (deal_watch, finance_watch, github_watch, news_brief) and Scout/PWA as primary UI.
- **Long-term technical vision** (in-process inference, eBPF, browser, task decomposition, WASM): [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md).

---

## Mutual Supervision (FLEET-001)

Mac and Pixel supervise each other via two scripts shipped in `scripts/`:

### Mac → Pixel: restart Mabel

```bash
bash scripts/restart-mabel.sh [--force] [--dry-run]
```

Env vars (from `.env`): `PIXEL_SSH_HOST` (default `termux`), `PIXEL_SSH_PORT` (default `8022`).

Stops any running `chump --discord` process on Pixel, calls `ensure-mabel-bot-up.sh`,
then polls until `pgrep -f 'chump.*--discord'` confirms Mabel is running (up to 15s).
Exit 0 = success, exit 1 = SSH unreachable, exit 2 = Mabel didn't come up.

### Pixel → Mac: health probe

```bash
bash scripts/probe-mac-health.sh [--quiet]
```

Env vars: `MAC_WEB_HOST` (default `mac`), `MAC_WEB_PORT` (default `3000`),
`CHUMP_WEB_TOKEN` (Bearer token, optional).

Calls `GET /api/dashboard` on Mac, parses `fleet_status` from the JSON response.
Exit 0 = green, exit 1 = yellow/unreachable, exit 2 = red.

### Integration test checklist

1. Start Chump on Mac with `CHUMP_WEB_TOKEN=test bash ./chump --web`.
2. From Pixel: `MAC_WEB_HOST=<mac-tailscale-ip> MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=test bash scripts/probe-mac-health.sh` → expect exit 0.
3. From Mac: `bash scripts/restart-mabel.sh --dry-run` → confirm printed SSH commands look correct.
4. From Mac with live Pixel: `bash scripts/restart-mabel.sh` → confirm Mabel restarts and comes up within 15s.
5. Simulate degraded fleet: stop Chump heartbeat on Mac, re-run probe → expect exit 1 or 2.
