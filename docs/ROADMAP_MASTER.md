# Master roadmap (navigation hub)

**Purpose:** One page that **sections** all roadmap-related docs so humans, Chump, and Cursor know **where the source of truth lives** for each kind of work. This file does **not** replace checkboxes in [ROADMAP.md](ROADMAP.md) or item tables in [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md); it **organizes** them.

**Read order (minimal):**

1. [ROADMAP.md](ROADMAP.md) + [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) at round start.  
2. This master doc when you need **orientation** or **phase IDs** for handoffs.  
3. [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) when choosing **what to build next** by phase (A→G, **I** on a calendar, **H** someday — see pragmatic doc).

---

## 1. Execution and checkboxes (source of truth for “what’s next”)

| Resource | Role |
|----------|------|
| [ROADMAP.md](ROADMAP.md) | **Canonical task list:** unchecked items, priorities, fleet lines. Mark work done here when it merges. |
| [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) | Focus, conventions, quality, what “good” looks like for the product. |
| [AGENTS.md](../AGENTS.md) | Chump–Cursor roles, handoffs, what to read per run. |
| [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md) | Message types, lifecycle, direct API expectations. |

**Bots:** Heartbeat / Discord / delegated agents should **not** invent scope—pick from ROADMAP, the task queue, or a prompt that cites a **phase + id** (e.g. “E1 screenshot” from Section 2 below).

---

## 2. Phased achievable plan (A–I)

**Authoritative detail:** [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) (full tables, gates, notes).

| Phase | Theme | Gate (summary) |
|-------|--------|------------------|
| **A** | Reliability & observability | None; single machine |
| **B** | Autonomy loop (tasks → done/blocked) | A4 / tests acceptable |
| **C** | Fleet symbiosis (Mac + Pixel, reports, hybrid inference) | B3 **or** B4 started (trust autonomy on a schedule) |
| **D** | PWA / brain workflows (research, capture, watch, briefing) | PWA in use |
| **E** | Tools & safety (vision, **sandbox_run**) | B2 partial |
| **F** | Consciousness wiring (optional; metrics/demos) | Someone cares about dashboards |
| **G** | Frontier research (G1 quantum toy, **G2** TDA on blackboard traffic, G3 workspace merge) | Gates in [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) Phase G + [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) §3 |
| **I** | Repo hygiene & storage | None; periodic maintenance |
| **H** | Someday platform (mistral.rs, eBPF, JIT WASM, …) | [TOP_TIER_VISION.md](TOP_TIER_VISION.md) |

**Also:** “Recommended default order” and **maintenance** notes live at the bottom of [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md).

### 2.1 Backlog snapshot (what is still open)

Use this when resuming work after a break; then pick **one** concrete task per PR (see [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md)).

| Source | Still open (summary) |
|--------|----------------------|
| [ROADMAP.md](ROADMAP.md) | Phase 2 **market research execution** (≥5 blind sessions, ≥8 interviews); wishlist “other” line; **Section 3** frontier: quantum cognition prototype, TDA metric, **workspace merge for fleet**. |
| [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) | **Phases 1–3, 5–7, 9–16:** semantic context, smart edits, autonomy planner refactor, delegate preprocessor, sandbox, swarm dispatch, entity extraction, Sentinel, atomic commits, schema SLA, OTel, prefix cache, async tools, streaming UI, fast lane — see unchecked `- [ ]` lines in that file. **Phase 8 (swarm toggle)** and **Task 4.2 (UI stripping)** are done in code; optional persistence of raw `<thinking>` to dedicated memory rows is still incremental. |
| [CLAUDE_COWORK_UPGRADE_PLAN.md](CLAUDE_COWORK_UPGRADE_PLAN.md) | **Phases 1–5** Cowork execution plan (defaults, FTS5 context, benchmarks, state machine, schemas, patch tool). **Phase 6** flag + mesh + executor scaffold shipped; Tailscale map-reduce not authorized until you extend Phase 6. |
| [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) | **Cowork desktop UI:** Tauri-wrapped PWA, IPC events, execution sidebar, masked thinking, approval modal; Phases 1–3 unchecked until built. |

---

## 3. Vision and ecosystem (why, not just what)

| Doc | Role |
|-----|------|
| [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) | **North-star vision:** theory → shipped code → near/medium term → frontier; metrics table. |
| [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) | Horizons (Now / Next / Later) and deployment order. |
| [ROADMAP_FULL.md](ROADMAP_FULL.md) | Broad Priority 1–5 backlog + history; use **pragmatic** phases for ordering. |

---

## 4. Consciousness, metrics, and architecture decisions

| Doc | Role |
|-----|------|
| [METRICS.md](METRICS.md) | Definitions: surprisal, phi, speculative batch, SQL snippets. |
| [ROADMAP_REMAINING_GAPS.md](ROADMAP_REMAINING_GAPS.md) | Post–Phase F backlog: **ADR-001** transactional speculation (not the same as pragmatic **Phase G / G2**), sandbox hardening, optional test/DB isolation. |
| [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) | **Decision record:** memory-only rollback today vs future dry-run / sandbox integration. |
| [CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md) | External-review framing (engineering, non-claims). |

**Code touchpoints (reference):** `speculative_execution`, `sandbox_tool` (`sandbox_run`), `agent_loop` (≥3-tool batch), `surprise_tracker`, `blackboard`, `memory_graph`, `counterfactual`.

---

## 5. Fleet, Mabel, Android, autonomy workflows

| Doc | Role |
|-----|------|
| [FLEET_ROLES.md](FLEET_ROLES.md) | Chump, Mabel, Scout; expansion priority. |
| [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) | Mabel heartbeat driver (patrol, research, report, intel, …). |
| [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) | Farmer Brown, Sentinel, Shepherd on Pixel. |
| [ROADMAP_ADB.md](ROADMAP_ADB.md) | ADB / companion / Termux. |
| [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) | Tasks, PRs, round types. |
| [OPERATIONS.md](OPERATIONS.md) | Env, roles, battle QA, mutual supervision, hybrid inference. |

---

## 6. Sprint-style and historical plans

| Doc | Role |
|-----|------|
| [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md) | Sprints 1–4 master plan; status at top. |
| [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) | Tower, tracing, pool, macros—infrastructure status. |

Use these when a handoff says “sprint X” or when aligning infra work with the phased plan.

---

## 7. Full doc index

All guides (run, ops, reference) are listed in **[docs/README.md](README.md)**. Use the tables there for setup, inference, Discord, web API, and Chump–Mabel specifics.

---

## Version

Introduced as the **master navigation hub** for roadmap docs; keep **ROADMAP.md** and **ROADMAP_PRAGMATIC.md** as the writable sources of truth for checkboxes and phase items. Update this file when new roadmap **tiers** appear (new ADR, new phase letter, or major rename). Ongoing consistency: **`.cursor/rules/roadmap-doc-hygiene.mdc`** and **docs/CURSOR_CLI_INTEGRATION.md** §3.4 (recurring handoff).
