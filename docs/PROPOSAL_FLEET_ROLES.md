# Proposal: Fleet Roles

Full proposal text for the three-role fleet architecture. The summary is in [FLEET_ROLES.md](FLEET_ROLES.md).

## The proposal

**Problem:** The fleet (Mac + Pixel + iPhone) is underutilized. Chump runs on Mac as a coding agent. Mabel runs on Pixel as a fleet monitor. Scout (iPhone) barely exists. The compute, always-on nature of Pixel, and daily-driver role of iPhone are untapped.

**Proposed roles:**

| Node | Old role | New role | Core capability |
|------|----------|----------|-----------------|
| Mac (Chump) | Self-improvement coding agent | **Forge** | Builder, researcher, analyst; works on any repo |
| Pixel (Mabel) | Fleet monitor | **Sentinel** | 24/7 watch rounds, uptime, morning brief |
| iPhone (Scout) | Rarely used | **Interface** | PWA chat, iOS Shortcuts, quick capture |

**Shared infrastructure:**
- `chump-brain/` shared across Mac + Pixel (sync via git or rsync)
- `brain/research/`, `brain/watch/`, `brain/capture/`, `brain/projects/`, `brain/reports/`
- Task `assignee` field: `chump | mabel | jeff | any`
- Chump Web API as the north-south bus (Scout → Mac + ingest from Mabel)

## Implementation priority

1. **Chump Web PWA full Tier 2** — Gateway to everything else (12d effort)
2. **Research pipeline** — Chump research rounds → brain/research/ (2d)
3. **Mabel watch rounds** — deals, finance, GitHub, news brief (2d)
4. **Morning briefing** — Mabel synthesis → push notification (1d)
5. **Quick capture** — iPhone Shortcut → brain/capture/ (1d)
6. **Multi-repo work** — Chump works on external projects (1d)
7. **iOS Shortcuts** — deploy, status, create task, capture (0.5d each)
8. **Task routing with assignee** — multi-agent coordination (1d)

## Critical path

Chump Web PWA is the bottleneck. Every feature above depends on `/api/chat`, `/api/tasks`, `/api/briefing`, or push notifications being production-ready.

## See Also

- [FLEET_ROLES.md](FLEET_ROLES.md) — summary + fleet transport spike design
- [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Mabel evolution roadmap
- [ANDROID_COMPANION.md](ANDROID_COMPANION.md) — Pixel setup
- [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) — PWA feature spec
