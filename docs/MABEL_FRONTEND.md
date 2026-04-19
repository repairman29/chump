# Mabel Frontend

UI and interaction design for Mabel, the Pixel-based companion agent. Mabel's primary interface is Discord + SSH; this doc covers the frontend surfaces she has or could have.

See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) for Mabel's roadmap and [A2A_DISCORD.md](A2A_DISCORD.md) for the Discord A2A protocol.

## Current surfaces

### Discord (primary)

Mabel sends and receives messages in a dedicated Discord channel. Messages are routed via the `a2a_discord` adapter.

- **Inbound:** Mabel can receive task assignments and approvals from Discord
- **Outbound:** Fleet reports, alerts, and watch-round results are posted to Discord
- **Format:** Markdown-formatted messages; code blocks for JSON payloads

### SSH terminal (operational)

When on the Pixel, Mabel's Termux session is the operational surface:
- `heartbeat-mabel.sh` runs in a `tmux` session
- Logs stream to `~/chump/logs/mabel-*.log`
- `diagnose-mabel-model.sh` runs interactively for model health checks

### Web API bridge (one-way)

Mabel reads `GET /api/dashboard` from the Mac via Tailscale. No direct UI for this; it feeds the fleet report.

## Planned surfaces

### Scout interface (Phase 4 in ROADMAP_MABEL_DRIVER.md)

A minimal read-only Termux web UI (single-file HTML, no build step) showing:
- Mac fleet status (derived from `/api/dashboard`)
- Current ship heartbeat round
- Last 10 Discord messages
- Pending approval requests

**Design constraints:** no Node, no npm, no bundler — single `index.html` with vanilla JS + `EventSource` for SSE.

### Morning briefing (Phase 3)

Mabel posts a morning briefing to Discord at 8am local time:
- Outstanding approvals
- Overnight ship heartbeat summary
- Any fleet anomalies from the night

**Status:** Stub in `heartbeat-mabel.sh` intel round; content not yet structured.

## Interaction design notes

Mabel's persona: **watchful, terse, helpful**. She doesn't generate long prose. Her messages are structured:

```
[MABEL] 08:00 Fleet report
Mac: UP | vLLM: UP (8000) | Ollama: UP
Chump: ship round 3/7 (in progress, +12m)
Pending approvals: 0
Last anomaly: none
```

Human-addressed messages start with `@jeff` when the content requires human decision.

## See Also

- [A2A_DISCORD.md](A2A_DISCORD.md) — Discord A2A protocol
- [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Mabel's roadmap
- [OPERATIONS.md](OPERATIONS.md) — heartbeat-mabel.sh operational reference
