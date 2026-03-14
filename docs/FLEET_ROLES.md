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

## Relation to existing roadmaps

- **Chump:** [ROADMAP.md](ROADMAP.md) — Fleet expansion (external work, research rounds, review round) is the next horizon after current unchecked items.
- **Mabel:** [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Extends with watch rounds (deal_watch, finance_watch, github_watch, news_brief) and Scout/PWA as primary UI.
