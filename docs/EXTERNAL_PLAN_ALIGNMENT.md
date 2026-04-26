---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# External Plan Alignment

Living map of the external strategy paper (defense/high-assurance positioning) against implementation in this repo. Work packages (WP-IDs) are defined in [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md).

## Alignment map

| External requirement | WP | Implementation | Status |
|--------------------|----|---------------|--------|
| Transparent approval surfaces | WP-1 | `CHUMP_TOOLS_ASK`, `/api/approve`, tool approval UI | ✓ Shipped |
| Sandboxed shell execution | WP-2 | `sandbox` tool + `CHUMP_SANDBOX_SPECULATION=1` | ✓ Shipped |
| Policy override API | WP-3 | `CHUMP_AUTO_APPROVE_*`, `CHUMP_EXECUTIVE_MODE` | ✓ Shipped |
| Audit trail export | WP-4 | `chump_tool_health` ring buffer + `/api/pilot-summary` | ✓ Shipped |
| Air-gap operation | WP-5 | `CHUMP_AIR_GAP_MODE=1` (disables web_search + read_url) | ✓ Shipped |
| Belief tool budget (epistemic caution) | WP-6.1 | `CHUMP_BELIEF_TOOL_BUDGET=1` | ✓ Shipped |
| In-process inference (no cloud) | WP-7 | `CHUMP_INFERENCE_BACKEND=mistralrs` | ✓ Partial (ISQ tuning pending) |
| Containerized execution profile | WP-8 | `run_cli` governance + sponsor-safe defaults documented | ✓ Documented |
| MCP sandboxscan classification | RFC | [rfcs/RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md) | 🔧 RFC filed |
| Multimodal RFC (image+vision) | WP-1.5 | ACP `session/prompt` with image blocks | ✓ Shipped |
| Inference backends RFC | — | [rfcs/RFC-inference-backends.md](rfcs/RFC-inference-backends.md) | ✓ Filed |

## Key decisions

**Scope priority:** inference/ops → pilot kit → fleet transport → research/RFCs (in that order per ROADMAP.md §Alignment).

**run_cli governance:** Sponsor-safe defaults for demos: `CHUMP_TOOLS_ASK=run_cli,git_push,git_commit`, `CHUMP_AUTO_APPROVE_*` all off. See [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md).

**Containerized execution:** Optional SSH-jump or container execution profile is tracked as a follow-up issue but not yet wired. `sandbox` tool (git worktree isolation) is the interim pattern.

## Theme status

| Theme | Status |
|-------|--------|
| Inference / ops | ✓ WP-1 through WP-7 shipped |
| Pilot kit | ✓ Defense repro kit + WEDGE_PILOT_METRICS |
| Fleet transport | ✓ Spike design complete; WebSocket/MQTT prototype pending |
| Research / RFCs | ✓ RFC-inference-backends + RFC-wp23-mcp filed |

## See Also

- [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) — full WP details and pilot recipe
- [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) — step-by-step pilot setup
- [rfcs/](rfcs/) — RFC directory
