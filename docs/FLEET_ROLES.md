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

## Relation to existing roadmaps

- **Chump:** [ROADMAP.md](ROADMAP.md) — Fleet expansion (external work, research rounds, review round) is the next horizon after current unchecked items.
- **Mabel:** [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Extends with watch rounds (deal_watch, finance_watch, github_watch, news_brief) and Scout/PWA as primary UI.
- **Long-term technical vision** (in-process inference, eBPF, browser, task decomposition, WASM): [TOP_TIER_VISION.md](TOP_TIER_VISION.md).
