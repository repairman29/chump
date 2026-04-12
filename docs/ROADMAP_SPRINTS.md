# Roadmap sprints — full backlog through “planning complete”

**Purpose:** Map **every major open work source** in this repo to **named sprints** with goals and exit criteria. This is the **long-road plan**: execution happens sprint-by-sprint afterward; update this file when scope shifts.

**What “100% planned” means here:** Each backlog source in **§8 Coverage** has at least one **Sprint ID**. It does **not** mean every line item is implemented—only that nothing in those sources is orphaned from a sprint bucket.

**Source of truth for checkboxes:** [ROADMAP.md](ROADMAP.md). **Phased engineering map:** [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md). **Navigation:** [ROADMAP_MASTER.md](ROADMAP_MASTER.md).

**Maintenance:** After each sprint closes, check off items in `ROADMAP.md`, update §8 if a new doc appears, and bump **Last reconciled** at the bottom.

---

## Sprint overview

| Sprint | Theme | Primary sources | Exit criteria (planning) |
|--------|--------|-----------------|---------------------------|
| **S1** | Market evidence | ROADMAP Phase 2 research | ≥5 blind B1–B5 logged + ≥8 interviews in [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §4.4; refresh §2b scores |
| **S2** | Mistral — model substrate | ROADMAP mistral §; WP-1.5; [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) | RFC multimodal **Accepted** or **Rejected** with written rationale; if Accepted, RFC phase-1 scope merged or ticketed with owners |
| **S3** | Mistral — reliability of tools | ROADMAP structured output line; matrix “structured output / grammar” | Spike in `mistralrs_provider` documented (ADR or matrix row): constraint API chosen, battle QA / smoke path defined |
| **S4** | Tools & perception | [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) E1; [WISHLIST.md](WISHLIST.md) | Vision path (screencap → model) behind env; privacy note in OPERATIONS; **or** explicit defer with issue link |
| **S5** | Watch / edit awareness | WISHLIST `watch_file (full)` | Design + incremental PR: “Jeff edited X since last run” in context or session prelude |
| **S6** | Streaming parity (optional product) | Matrix “Still open” streaming row; WP-1.6 extension | RFC or ADR: Discord **standard** turns vs HTTP `LocalOpenAI` SSE—pick one first; acceptance tests listed |
| **S7** | Frontier — quantum cognition | [ROADMAP.md](ROADMAP.md) CHUMP_TO_COMPLEX §3; [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) G1 | Gate experiment run; document pass/fail vs >5% synthetic benchmark; merge or close |
| **S8** | Frontier — TDA integration metric | ROADMAP §3; pragmatic G2 | Same: correlate vs phi_proxy or document negative result |
| **S9** | Frontier — fleet workspace | ROADMAP §3 workspace merge; pragmatic G3 | Spike: bounded peer_sync blackboard merge; security + conflict model doc |
| **S10** | Claude-tier upgrade (batch 1) | [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phases 1–4 (see file) | Unchecked items in those phases each assigned to a PR sequence in file or sub-bullet here |
| **S11** | Claude-tier upgrade (batch 2) | ROADMAP_CLAUDE Phases 5–8, 9–12 | Same |
| **S12** | Claude-tier upgrade (batch 3) | ROADMAP_CLAUDE Phases 13–16 + remainder | Same; goal: zero unchecked or explicit “won’t do” with reason |
| **S13** | Cowork desktop shell | [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) | All phases checked or re-scoped with dates |
| **S14** | Cowork mesh / tail | [CLAUDE_COWORK_UPGRADE_PLAN.md](CLAUDE_COWORK_UPGRADE_PLAN.md) Phase 6+ | Tailscale map-reduce: authorized or permanently deferred |
| **S15** | Governance adopt (conditional) | [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) WP-7.2 | Only if sponsor adopts WP-7.1 recommendation; else sprint = “no-op” with annual review |
| **S16** | Someday promotion | [TOP_TIER_VISION.md](TOP_TIER_VISION.md); pragmatic Phase H | Each H item either linked to a future sprint or marked out-of-scope for 12 months |

---

## Sprint detail (execution hints)

### S1 — Market research execution

- **Work:** Human-led sessions; no code requirement to close.
- **Depends on:** None.

### S2 / S3 — Mistral.rs

- **S2:** Aligns with [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) and [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) backlog §7.
- **S3:** Tool JSON reliability; may proceed in parallel with S2 after spike scoping.
- **Measurement:** [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md), `scripts/mistralrs-inference-ab-smoke.sh`.

### S4 / S5 — Wishlist tools

- **S4** maps **E1**; reuse `CHUMP_VISION_*` / screen tooling patterns in [screen_vision_tool.rs](../src/screen_vision_tool.rs) if applicable.
- **S5** is documentation-heavy (where to log edits, FTS, or file watcher).

### S6 — Streaming parity

- **Scope control:** Pick **Discord standard** *or* **HTTP provider streaming** first; second follows.
- **Refs:** [RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) (extension), [streaming_provider.rs](../src/streaming_provider.rs).

### S7–S9 — Frontier

- **Rule:** Time-box each; failure to meet gate is a successful outcome if written up in `METRICS.md` or episode.

### S10–S12 — ROADMAP_CLAUDE_UPGRADE

- **~31 unchecked lines** (as of 2026-04): do **not** duplicate here—use the file’s phase headings as the internal task list.
- **S10** = early phases (context, edits, autonomy scaffolding); **S11** = mid (swarm, sentinel, commits); **S12** = late (OTel, streaming UI, fast lane). Re-balance if phases shift.

### S13–S14 — Desktop + Cowork

- **S13:** Tauri IPC, PWA wrap, approval UX per TAURI plan.
- **S14:** Network-authorized features only after explicit go-ahead in Cowork plan.

### S15 — WP-7.2

- Blocked on sponsor **adopt** for agent-governance RFC; sprint exists so the registry is not silent.

### S16 — Phase H / TOP_TIER

- Quarterly review: promote item to S2–S14 or leave in H.

---

## Backlog coverage — sources → sprints

| Source | Sprint(s) | Notes |
|--------|-----------|--------|
| [ROADMAP.md](ROADMAP.md) unchecked lines | S1, S2, S3, S4, S5, S7, S8, S9, (+ wishlist narrative S4/S5) | Canonical checkboxes |
| [WISHLIST.md](WISHLIST.md) | S4, S5 | introspect/sandbox marked Done in wishlist |
| [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) Next tier / streaming gaps | S2, S3, S6 | Agent power **path** doc already shipped |
| [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) WP-1.5 Partial, WP-7.2 Blocked | S2, S15 | Rest Done |
| [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) | S10, S11, S12 | Line items stay in that file |
| [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) | S13 | |
| [CLAUDE_COWORK_UPGRADE_PLAN.md](CLAUDE_COWORK_UPGRADE_PLAN.md) tail | S14 | |
| [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) E1, G1–G3 | S4, S7–S9 | E2 sandbox Done |
| [TOP_TIER_VISION.md](TOP_TIER_VISION.md) / Phase H | S16 | |
| [ROADMAP_REMAINING_GAPS.md](ROADMAP_REMAINING_GAPS.md) | S3, S6, S10–S12 | Map each gap to nearest sprint when touching code |

---

## Recommended execution order (first six sprints)

If you must serialize: **S1** (parallel human) **· S2+S3** (mistral substrate) **· S4** (vision) **· S10 start** (Claude-tier highest ROI items per your product) **· S6** (streaming) **· S7–S9** only with explicit research week.

---

## Sprint execution log

| Date (UTC) | Sprint | Outcome |
|------------|--------|---------|
| 2026-04-09 | **S10** | [CONTEXT_ASSEMBLY_AUDIT.md](CONTEXT_ASSEMBLY_AUDIT.md) shipped; ROADMAP_CLAUDE_UPGRADE **Task 1.1** checked off. |
| 2026-04-09 | **S10** | Phase 1 **Tasks 1.2–1.3**: `apply_sliding_window_to_messages_async`, **`CHUMP_CONTEXT_HYBRID_MEMORY`**, unit tests in `local_openai.rs`. |
| 2026-04-12 | **S3** | Structured output spike: [ADR-002](ADR-002-mistralrs-structured-output-spike.md), **`CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA`**, `scripts/mistralrs-structured-smoke.sh`, matrix + `.env.example` updates. |

---

**Last reconciled:** 2026-04-12 (S3 mistral structured-output spike; S10 history unchanged).
