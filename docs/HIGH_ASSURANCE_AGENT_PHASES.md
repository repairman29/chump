# High-assurance autonomous agents — phased plan (paper → Chump)

**At a glance**

- **What this is:** A **work-package (WP) registry** that turns long-form strategy papers (mistral.rs, Active Inference, WASM/MCP safety, fleet, SDA positioning) into **single-Cursor-run** tasks with **Goal / Source / Paths** per [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md).
- **What this is not:** A promise that every cited external product (Agent Governance Toolkit, MCP-SandboxScan, Symthaea, swarms-rs) ships in-tree; those are **gated** under Phase 7 or explicit RFCs.
- **Where to start:** §3 **Work package registry** → pick one row → copy §4 **Handoff template** → execute one WP per delegation.

---

## Document control

| Field | Value |
|-------|--------|
| **Canonical path** | `docs/HIGH_ASSURANCE_AGENT_PHASES.md` |
| **Companion (short alignment)** | [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md) — claims vs repo, one-page phased *order* |
| **Execution checkboxes** | [ROADMAP.md](ROADMAP.md) → *Strategic evaluation alignment* → line linking this file |
| **WP status values** | **Open** (not started) · **Partial** (started / docs only / spike) · **Done** (merged + acceptance met) · **Blocked** (dependency / sponsor) · **Deferred** (explicitly parked) |
| **Priority** | **P0** = defense / stability first · **P1** = product depth · **P2** = research / optional |
| **Machine-readable export** | **Markdown §3 only** for now (WP-IDs are grep-friendly). Add `docs/high_assurance_wps.json` or an export script only when Chump or CI needs programmatic sync. |

**Maintenance:** When a WP merges, set its **Status** to **Done** in §3, follow **§21**, and bump **§19 Changelog**. When the external paper changes materially, reconcile §5–§14 and [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md) in the same PR or a follow-up within one week.

---

## Table of contents

1. [Planning doc roles (which file is source of truth for what)](#1-planning-doc-roles-which-file-is-source-of-truth-for-what)  
2. [Glossary](#2-glossary)  
3. [Work package registry (master)](#3-work-package-registry-master)  
4. [Handoff template (Chump → Cursor)](#4-handoff-template-chump--cursor)  
5. [Phase map (paper themes → pragmatic phases A–H)](#5-phase-map-paper-themes--pragmatic-phases-ah)  
6. [Phase 0 — Baseline (shipped)](#6-phase-0--baseline-shipped)  
7. [Phase 1 — Inference substrate](#7-phase-1--inference-substrate)  
8. [Phase 2 — WASM and tool boundaries](#8-phase-2--wasm-and-tool-boundaries)  
9. [Phase 3 — Middleware and load control](#9-phase-3--middleware-and-load-control)  
10. [Phase 4 — Air-gap and compliance posture](#10-phase-4--air-gap-and-compliance-posture)  
11. [Phase 5 — Fleet symbiosis](#11-phase-5--fleet-symbiosis)  
12. [Phase 6 — Cognitive architecture](#12-phase-6--cognitive-architecture)  
13. [Phase 7 — External governance evaluation](#13-phase-7--external-governance-evaluation)  
14. [Phase 8 — Mission narratives](#14-phase-8--mission-narratives)  
15. [WP dependencies](#15-wp-dependencies)  
16. [Suggested execution order](#16-suggested-execution-order)  
17. [Closing the parent ROADMAP checkbox](#17-closing-the-parent-roadmap-checkbox)  
18. [Air-gap: candidate outbound tools (for WP-4.1)](#18-air-gap-candidate-outbound-tools-for-wp-41)  
19. [Changelog](#19-changelog)  
20. [Verification profiles (minimum gates per WP)](#20-verification-profiles-minimum-gates-per-wp)  
21. [Anti-drift checklist (on WP merge)](#21-anti-drift-checklist-on-wp-merge)

---

## 1. Planning doc roles (which file is source of truth for what)

| Artifact | Role | Updates when |
|----------|------|--------------|
| [ROADMAP.md](ROADMAP.md) | **Product-wide** checkboxes; fleet, battle QA, market, *one umbrella* line pointing here | Item completes; Chump/Cursor policy |
| [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md) | **Short** map: paper claims ↔ repo reality; recommended *order* of themes | New external paper revision |
| **This file** | **Granular WPs:** IDs, paths, acceptance, status, dependencies | Every WP start/finish or scope change |

**Rule:** Do not duplicate full WP tables into ROADMAP.md. Use **WP-ID** in Cursor prompts and update **Status** here.

---

## 2. Glossary

| Term | Meaning |
|------|---------|
| **WP** | Work package — one delegated Cursor run (one PR ideal). |
| **Air-gap mode** | Deployment posture: no outbound general-Internet tool use; enforced by config (WP-4.1), not physical air-gap alone. |
| **Bounded tool** | Tool with constrained semantics (e.g. `wasm_calc`, `wasm_text`); contrast **host-trust** (`run_cli`). |
| **SandboxScan-class (MCP)** | MCP-integrated scanners/analyzers with wide workspace read, subprocess/container use, and/or network (class definition: [RFC-wp23](rfcs/RFC-wp23-mcp-sandboxscan-class.md)). |

---

## 3. Work package registry (master)

| WP-ID | Phase | Priority | Status | Summary |
|-------|-------|----------|--------|---------|
| **WP-1.1** | 1 | P1 | Done | Runbook: mistral.rs in-process vs HTTP; `HF_TOKEN`, Metal/CPU, failures |
| **WP-1.2** | 1 | P1 | Done | Health + PWA hints when `CHUMP_INFERENCE_BACKEND=mistralrs` |
| **WP-1.3** | 1 | P2 | Done | RFC: mistral.rs MCP client vs sidecar; no prod flip without battle QA |
| **WP-2.1** | 2 | P1 | Done | Second WASM tool + tests (`WASM_TOOLS.md` checklist) |
| **WP-2.2** | 2 | P0 | Done | Trust ladder + pilot allowlist in [TOOL_APPROVAL.md](TOOL_APPROVAL.md), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) |
| **WP-2.3** | 2 | P2 | Done | RFC/ADR: MCP-SandboxScan-class wrapping; threat model |
| **WP-3.1** | 3 | P0 | Done | **`CHUMP_TOOL_MAX_IN_FLIGHT`** global semaphore in `tool_middleware` |
| **WP-3.2** | 3 | P1 | Done | Optional rate limit layer for tools |
| **WP-4.1** | 4 | P0 | Done | **`CHUMP_AIR_GAP_MODE`** disables outbound tools in §18 (**registration-time** in `tool_inventory.rs`) |
| **WP-4.2** | 4 | P1 | Done | RMF-style **template** doc; not legal ATO |
| **WP-5.1** | 5 | P1 | Done | Lab WS echo spike: [FLEET_WS_SPIKE_RUNBOOK.md](FLEET_WS_SPIKE_RUNBOOK.md), `scripts/fleet-ws-spike.sh`, **`fleet-ws-echo`** Rust client (`cargo run --bin fleet-ws-echo`) |
| **WP-5.2** | 5 | P1 | Done | Operator checklist in [INFERENCE_MESH.md](INFERENCE_MESH.md); hybrid Mabel pointers unchanged |
| **WP-6.1** | 6 | P2 | Done | `CHUMP_BELIEF_TOOL_BUDGET` → tighter `recommended_max_tool_calls()` **and** `recommended_max_delegate_parallel()` when uncertainty high; [METRICS.md](METRICS.md) §1a |
| **WP-6.2** | 6 | P2 | Done | [NEUROMODULATION_HEURISTICS.md](NEUROMODULATION_HEURISTICS.md); module doc cross-link |
| **WP-6.3** | 6 | P2 | Done | [RETRIEVAL_EVAL_HARNESS.md](RETRIEVAL_EVAL_HARNESS.md); holographic similarity probe test |
| **WP-7.1** | 7 | P2 | Done | [rfcs/RFC-agent-governance.md](rfcs/RFC-agent-governance.md) — recommend **defer adopt** |
| **WP-7.2** | 7 | P2 | Blocked | **Blocked** until sponsor chooses **adopt** in WP-7.1 + security review |
| **WP-8.1** | 8 | P1 | Done | [SDA_CHUMP_MAPPING.md](SDA_CHUMP_MAPPING.md) — traceable capability map + non-claims |

---

## 4. Handoff template (Chump → Cursor)

Paste and fill:

```
Goal: <one sentence from WP Summary + detailed Goal in phase section>
Source: docs/HIGH_ASSURANCE_AGENT_PHASES.md → Phase <N> → <WP-ID>
Paths or logs: <Primary paths from phase table>; <optional log paths>
Verify: per §20 profile for <WP-ID>.
```

**Cursor response must include:** outcome, files changed, whether **Status** in §3 was updated to **Done**, **§21** items satisfied, and suggested next WP.

---

## 5. Phase map (paper themes → pragmatic phases A–H)

| Paper theme | [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) phase | Chump focus today |
|-------------|-----------------------------------------------------|-------------------|
| mistral.rs substrate | **H** / **A** | Optional `mistralrs-infer` / `mistralrs-metal`; HTTP default |
| PagedAttention, ISQ, multimodal | **H** | Via mistral.rs when that backend is selected |
| Cascade / routers | **A** | `provider_cascade.rs`, [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) |
| Active Inference / EFE | **G** | [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md); `belief_state` — not driving tool choice |
| Neuromodulation / GWT / HRR | **G** / **F** | `neuromodulation`, `holographic_workspace`, `blackboard` |
| WASM sandboxing | **E** | `wasm_calc`, `wasm_text`, [WASM_TOOLS.md](WASM_TOOLS.md) |
| Tower / middleware | **A** | [tool_middleware.rs](../src/tool_middleware.rs): timeout + circuit breaker |
| MCP / governance / SandboxScan-class | **E** / external | Approvals + audit today; [RFC-wp23](rfcs/RFC-wp23-mcp-sandboxscan-class.md); Phase 7 for toolkit eval |
| Fleet WS/MQTT | **C** | [FLEET_ROLES.md](FLEET_ROLES.md), [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) |
| SDA / TAP narrative | Market / pilot | [DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md), WP-8.1 |

---

## 6. Phase 0 — Baseline (shipped)

**Objective:** Inventory already aligned with *parts* of the high-assurance paper.

- [x] Rust orchestrator; Discord / PWA / CLI; SQLite; Tailscale + SSH fleet patterns  
- [x] OpenAI-compatible HTTP inference + provider cascade  
- [x] Tool timeout + per-tool circuit breaker + approval + audit — [TOOL_APPROVAL.md](TOOL_APPROVAL.md), `tool_middleware`  
- [x] Speculative execution, `sandbox_tool`, battle QA discipline  
- [x] Inference ops hardening: degraded-mode playbook, PWA `stack-status` — [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md), [OPERATIONS.md](OPERATIONS.md)  
- [x] Pilot governance docs — [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md)  
- [x] Fleet transport **design** — outbound WS/MQTT spike notes  
- [x] Optional in-process mistral.rs — [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b, [RFC-inference-backends.md](rfcs/RFC-inference-backends.md)  

**No WP** unless regressing above.

---

## 7. Phase 1 — Inference substrate

**Objective:** Deepen **optional** mistral.rs **alongside** vLLM-MLX/Ollama.

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-1.1** | Document when to use in-process mistral.rs vs HTTP on Mac/Pixel; memory, ISQ, first-run download. | [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md), [OPERATIONS.md](OPERATIONS.md), `.env.example` | Runbook: `HF_TOKEN`, Metal vs CPU, failure modes, Pixel constraints | Done |
| **WP-1.2** | Health + PWA do not imply “HTTP model dead” when mistral.rs backend is active. | `src/web_server.rs`, `src/health_server.rs`, `web/index.html` | Contract documented in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) or OPERATIONS | Done |
| **WP-1.3** | Decide on mistral.rs **MCP client** for tool discovery (vs Chump registry). | [rfcs/RFC-wp13-mistralrs-mcp-tools.md](rfcs/RFC-wp13-mistralrs-mcp-tools.md), [rfcs/RFC-inference-backends.md](rfcs/RFC-inference-backends.md) | Written decision; battle QA before any default-on | Done |

**Non-goals:** Remove `serve-vllm-mlx*.sh`; mandate mistral.rs; adopt swarms-rs.

---

## 8. Phase 2 — WASM and tool boundaries

**Objective:** More **bounded** tools; honest **host-trust** story for `run_cli`.

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-2.1** | Add a **second** WASM tool (non-calculator) per [WASM_TOOLS.md](WASM_TOOLS.md). | `src/wasm_*`, `wasm/text-wasm`, [WASM_TOOLS.md](WASM_TOOLS.md) | Registered + tests; `wasm_runner` still no host FS/network | Done |
| **WP-2.2** | Clarify **trust ladder**: WASM bounded vs `run_cli` vs approvals; pilot allowlist. | [TOOL_APPROVAL.md](TOOL_APPROVAL.md), `src/cli_tool.rs`, [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md), [WASM_TOOLS.md](WASM_TOOLS.md), `.env.example` | Sponsor-readable table + demo script; explicit “host shell ≠ WASM” | Done |
| **WP-2.3** | MCP-SandboxScan-class **analysis** (ADR/RFC + threat model). | [RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md) | No production wrapper until scoped | Done |

---

## 9. Phase 3 — Middleware and load control

**Objective:** Composable limits without full Tower rewrite.

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-3.1** | **Concurrency** cap (global) in middleware via **`CHUMP_TOOL_MAX_IN_FLIGHT`**. | `src/tool_middleware.rs`, `src/health_server.rs`, [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md), `.env.example` | `0` = unlimited; **GET /health** → `tool_max_in_flight`; tests green | Done |
| **WP-3.2** | **Rate limit** (simple window or token bucket) for selected tools. | `src/tool_middleware.rs`, [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md), [OPERATIONS.md](OPERATIONS.md), `.env.example` | Documented env; safe defaults; **GET /health** → `tool_rate_limit` | Done |

---

## 10. Phase 4 — Air-gap and compliance posture

**Objective:** **Config + docs** for regulated deployments; **not** legal ATO.

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-4.1** | **`CHUMP_AIR_GAP_MODE=1`** disables tools in §18 at **tool registration** (`web_search`, `read_url` omitted). | `src/env_flags.rs`, `src/config_validation.rs`, `src/tool_inventory.rs`, `src/discord.rs`, `src/tool_routing.rs`, `src/web_server.rs`, `.env.example` | Docs: [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md), [OPERATIONS.md](OPERATIONS.md), [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md); `stack-status.air_gap_mode` | Done |
| **WP-4.2** | RMF-style **Markdown templates** (placeholders; not legal advice). | [COMPLIANCE_TEMPLATES.md](COMPLIANCE_TEMPLATES.md), [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md), [docs/README.md](README.md) | Offline-fillable; no cloud API required | Done |

---

## 11. Phase 5 — Fleet symbiosis

**Objective:** Connectivity beyond SSH; clear hybrid inference ops.

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-5.1** | Time-boxed **prototype**: outbound WS or MQTT Pixel→Mac. | [FLEET_WS_SPIKE_RUNBOOK.md](FLEET_WS_SPIKE_RUNBOOK.md), `scripts/fleet-ws-spike.sh`, `src/bin/fleet_ws_echo.rs`, [FLEET_ROLES.md](FLEET_ROLES.md) | Lab echo: **websocat** and/or **`fleet-ws-echo`**; not production transport | Done |
| **WP-5.2** | **Runbook**: Mac load vs Pixel local model; `MABEL_HEAVY_MODEL_BASE`. | [INFERENCE_MESH.md](INFERENCE_MESH.md), [OPERATIONS.md](OPERATIONS.md) | Operator checklist (WP-5.2) in INFERENCE_MESH; optional auto-routing = future WP | Done |

---

## 12. Phase 6 — Cognitive architecture

**Objective:** Measurable hooks; **no** paper-grade FEP claims.

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-6.1** | Uncertainty / EFE **signals** adjust exploration (tool budget, delegate). | `src/env_flags.rs`, `src/precision_controller.rs`, `src/delegate_tool.rs`, `src/belief_state.rs`, [METRICS.md](METRICS.md) | Belief budget: tool cap + delegate parallelism; unit tests; METRICS §1a | Done |
| **WP-6.2** | Neuromodulation ↔ timeouts / sampling; document as **heuristic**. | `src/neuromodulation.rs`, `src/tool_middleware.rs`, `src/precision_controller.rs`, [NEUROMODULATION_HEURISTICS.md](NEUROMODULATION_HEURISTICS.md) | Context fraction + per-call tool timeout modulation; doc; battle QA green | Done |
| **WP-6.3** | Holographic + blackboard **retrieval eval** on fixtures. | `src/holographic_workspace.rs`, [RETRIEVAL_EVAL_HARNESS.md](RETRIEVAL_EVAL_HARNESS.md) | Harness doc + HRR probes + **blackboard→HRR** pipeline test | Done |

**Out of scope:** Symthaea, full swarms-rs — separate RFC if ever.

---

## 13. Phase 7 — External governance evaluation

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-7.1** | Architecture RFC: Microsoft Agent Governance Toolkit–class policy **sidecar vs in-process**. | [rfcs/RFC-agent-governance.md](rfcs/RFC-agent-governance.md) | Recommendation **defer adopt**; WP-7.2 remains blocked until sponsor | Done |
| **WP-7.2** | Minimal integration **if** WP-7.1 chooses adopt. | TBD | Security checklist + tests only after **WP-7.1** is **Done** and adoption is chosen | Blocked |

---

## 14. Phase 8 — Mission narratives

| ID | Goal | Primary paths | Acceptance | Status |
|----|------|---------------|------------|--------|
| **WP-8.1** | One-page **SDA / TAP–style** capability map (what Chump *does* ship). | [SDA_CHUMP_MAPPING.md](SDA_CHUMP_MAPPING.md), [DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md) | Every bullet traceable to code or doc | Done |

---

## 15. WP dependencies

```
WP-2.2 ──► informs WP-4.1 (air-gap story must match trust ladder)
WP-7.1 ──► blocks WP-7.2
WP-1.1 ──► nice before WP-1.2 (docs before UI contract)
```

No other hard deps; parallelize P0 across phases 2–4 where possible.

---

## 16. Suggested execution order

| Order | WP(s) | Rationale |
|-------|-------|-----------|
| 1 | **WP-4.1**, **WP-2.2** | Defense narrative + honest tooling story; low inference risk |
| 2 | **WP-3.1** | Stability under parallel tools |
| 3 | **WP-1.2** | UX correctness for mistral.rs adopters |
| 4 | **WP-5.2** then **WP-5.1** | Runbook before transport code |
| 5 | **WP-4.2**, **WP-8.1** | Templates + positioning when pilot active |
| 6 | **WP-2.1**, **WP-3.2**, **WP-1.1** finish, **WP-1.3** | Depth and RFCs |
| 7 | **WP-6.x** | Gate on metrics owner |
| 8 | **WP-7.1** | After sponsor asks for policy engine |

---

## 17. Closing the parent ROADMAP checkbox

[ROADMAP.md](ROADMAP.md) has one umbrella item linking this file. Use **either**:

- **Strict:** Mark it **done** when all **P0** WPs (**2.2** complete, **3.1**, **4.1**) are **Done** in §3, *or*  
- **Loose:** Keep umbrella **open** until Phases **1–5** are materially complete; still update §3 per WP.

Record which rule the team chose in the PR that first marks the umbrella `[x]`.

---

## 18. Air-gap: candidate outbound tools (for WP-4.1)

**Shipped (v1):** When **`CHUMP_AIR_GAP_MODE=1`** (or `true`), **`web_search`** and **`read_url`** are not registered (see `src/tool_inventory.rs`, `src/env_flags.rs`). Prompt routing tables and Discord system prompt include an air-gap notice; **`GET /api/stack-status`** exposes **`air_gap_mode`**.

**Minimum disabled** in v1:

| Tool name | Module | Risk |
|-----------|--------|------|
| `web_search` | `tavily_tool.rs` | General Internet |
| `read_url` | `read_url_tool.rs` | Arbitrary URL fetch |

**Audit** (extend list if warranted): tools using HTTP client for non-local endpoints (e.g. vision proxy, GitHub API, embedding providers). `run_cli` remains **host-trust** (cannot be “disabled” by air-gap flag alone without breaking semantics — document: **combine** with `CHUMP_TOOLS_ASK` / allowlist for pilots).

---

## 19. Changelog

| Date | Change |
|------|--------|
| 2026-04-11 | Initial phased plan from strategic paper. |
| 2026-04-11 | Pass 2–3: TOC, document control, master WP registry, priorities, dependencies, air-gap inventory, ROADMAP closure rule, cross-links standardized. |
| 2026-04-09 | Pass 4–6: protocol/CLI/pilot cross-links; canonical **`CHUMP_AIR_GAP_MODE`**; WP-7.2 **Blocked** until WP-7.1 **Done**; **§20** verification profiles; **§21** anti-drift; machine-readable export deferred (Markdown §3 only). |
| 2026-04-09 | **WP-4.1 Done:** `CHUMP_AIR_GAP_MODE` gates `web_search` / `read_url` at registration; config + routing + `stack-status` + pilot/ops docs. |
| 2026-04-09 | **WP-3.1 Done:** `CHUMP_TOOL_MAX_IN_FLIGHT` process-wide tool concurrency; health `tool_max_in_flight`. |
| 2026-04-09 | **WP-2.2 Done:** trust ladder (TOOL_APPROVAL + pilot kit + WASM cross-link); `cli_tool` module doc. **§17 strict P0** set complete (2.2, 3.1, 4.1); [ROADMAP.md](ROADMAP.md) umbrella checked. |
| 2026-04-09 | **WP-1.2 Done:** `/api/stack-status` `inference.primary_backend` + `openai_http_sidecar`; PWA stack pill / Providers / pilot intro / slow-model hint; `GET /health` skips HTTP model down when mistral.rs env is selected (`inference_backend` field). |
| 2026-04-09 | **WP-1.1 Done:** [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b runbook — when to use in-process vs HTTP, Metal/CPU build matrix, `HF_TOKEN` + first-run, memory/ISQ, failure-mode table, Pixel → llama-server HTTP only; [OPERATIONS.md](OPERATIONS.md) + `.env.example` pointers. |
| 2026-04-09 | **WP-1.3 Done:** [RFC-wp13-mistralrs-mcp-tools.md](rfcs/RFC-wp13-mistralrs-mcp-tools.md) — Chump registry only for tools; mistral.rs MCP discovery rejected as default; optional MCP→Chump bridge deferred (Phase 7 / new RFC). |
| 2026-04-09 | **WP-2.1 Done:** `wasm_text` tool + `wasm/text-wasm` → `text_transform.wasm`; shared `wasm_artifact_path` / input clamp in `wasm_runner`; docs + optional integration test when artifact present. |
| 2026-04-09 | **WP-2.3 Done:** [RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md) — class definition, STRIDE-oriented threat model, options, production gates; no MCP scanner bridge in tree. |
| 2026-04-09 | **WP-3.2 Done:** `CHUMP_TOOL_RATE_LIMIT_*` sliding-window per listed tool in `tool_middleware`; `GET /health` `tool_rate_limit`; docs + tests. |
| 2026-04-09 | **WP-4.2 Done:** [COMPLIANCE_TEMPLATES.md](COMPLIANCE_TEMPLATES.md) — offline RMF-style Markdown shells; linked from pilot execution + repro kit + docs index. |
| 2026-04-09 | **WP-5.1 Done:** [FLEET_WS_SPIKE_RUNBOOK.md](FLEET_WS_SPIKE_RUNBOOK.md) + `scripts/fleet-ws-spike.sh` (websocat lab echo). **WP-5.2 Done:** operator checklist in [INFERENCE_MESH.md](INFERENCE_MESH.md). |
| 2026-04-09 | **WP-6.1 Done:** `CHUMP_BELIEF_TOOL_BUDGET` tightens `recommended_max_tool_calls` under high epistemic uncertainty; [METRICS.md](METRICS.md) §1a. **WP-6.2 Done:** [NEUROMODULATION_HEURISTICS.md](NEUROMODULATION_HEURISTICS.md). **WP-6.3 Done:** [RETRIEVAL_EVAL_HARNESS.md](RETRIEVAL_EVAL_HARNESS.md) + holographic probe test. |
| 2026-04-09 | **WP-7.1 Done:** [RFC-agent-governance.md](rfcs/RFC-agent-governance.md) — defer adopt; WP-7.2 still blocked pending adopt + review. **WP-8.1 Done:** [SDA_CHUMP_MAPPING.md](SDA_CHUMP_MAPPING.md). |
| 2026-04-09 | **Deepening (no WP-ID change):** WP-6.1 delegate parallelism; WP-6.2 neuromod → tool timeout + context exploration fraction; WP-6.3 `sync_from_broadcast_entries` + pipeline test; WP-5.1 `fleet-ws-echo` binary; `/api/stack-status` **`cognitive_control`** + health **`precision`** extras. |

---

## 20. Verification profiles (minimum gates per WP)

**Profiles:** **Doc** = markdown acceptance only (review in PR). **Test** = `cargo test` (affected crates) green. **Battle** = `battle_qa` or smoke path named in WP/OPERATIONS. **Manual** = PWA/Discord or pilot steps; use [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) where UI surfaces change.

| WP-ID | Minimum verification |
|-------|----------------------|
| **WP-1.1** | Doc |
| **WP-1.2** | Doc; Manual (PWA/providers if contract changes) |
| **WP-1.3** | Doc (RFC); Battle before any default-on behavior |
| **WP-2.1** | Test; Battle |
| **WP-2.2** | Doc |
| **WP-2.3** | Doc (RFC/ADR) |
| **WP-3.1** | Test; Battle |
| **WP-3.2** | Test; Doc |
| **WP-4.1** | Test; Doc; Manual (pilot repro if tools change) |
| **WP-4.2** | Doc |
| **WP-5.1** | Doc; Manual (demo steps) |
| **WP-5.2** | Doc |
| **WP-6.1** | Test; Battle |
| **WP-6.2** | Doc; Battle |
| **WP-6.3** | Test; Doc |
| **WP-7.1** | Doc (RFC) |
| **WP-7.2** | Test; Doc; Manual (security checklist) — only after WP-7.1 **Done** |
| **WP-8.1** | Doc |

---

## 21. Anti-drift checklist (on WP merge)

When a WP reaches **Done** in the same PR (or immediately after merge):

1. **§3 Status** → **Done** for that WP-ID.  
2. **§19 Changelog** — add a dated line (what changed).  
3. **If runtime or contract changed** — update artifacts the WP’s acceptance names (typically `.env.example`, [OPERATIONS.md](OPERATIONS.md), [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)); do not rely on code alone.  
4. **ROADMAP umbrella** — touch [ROADMAP.md](ROADMAP.md) *Strategic evaluation alignment* only per **§17** (not after every WP by default).

---
