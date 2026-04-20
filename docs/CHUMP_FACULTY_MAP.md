# Chump Faculty Map — DeepMind 10-Faculty Coverage (2026-04-19)

## Purpose

This document maps Chump's modules onto DeepMind's 10-faculty AGI cognitive framework
([Measuring Progress Toward AGI, 2025](https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf)).
It serves two roles: a **positioning artifact** that tells external readers (Gemini reviewer,
prospective contributors, funders) what Chump actually exercises versus what it merely names;
and a **gap-surfacing instrument** that turns the question "what should we work on next?" into
an evidence-anchored answer. Every faculty row cites a concrete module path and, where
available, a specific EVAL-XXX gap with A/B-tested numeric results. Cells without evidence are
the research backlog.

## Coverage table

| # | Faculty | Chump module(s) | A/B evidence | Status |
|---|---|---|---|---|
| 1 | Perception | `chump-perception` crate, `crates/mcp-servers/chump-mcp-tavily` | EVAL-032 ablation flag shipped (`CHUMP_BYPASS_PERCEPTION`); sweep pending (n=100, two-judge, A/A calibration) | COVERED+UNTESTED (ablation flag shipped, sweep pending) |
| 2 | Generation | `src/agent_loop/`, `src/agent_loop/prompt_assembler.rs` | EVAL-023, EVAL-025, EVAL-026 (output quality deltas) | COVERED+VALIDATED |
| 3 | Attention | *no module today* | EVAL-028 pilot run (n≤5 per condition, harness ready, full n=50 sweep pending) | **GAP** (harness unblocked) |
| 3 | Attention | *no module today* | EVAL-028 PILOT (PR #138) + EVAL-028 real n=50 (lessons-under-distraction sweep, methodological retrofit needed) — proper CatAttack baseline awaits EVAL-028b cell-layout fix | **GAP** (harness exercised, faculty unmeasured) |
| 4 | Learning | `src/reflection_db.rs` (lessons block, COG-016), `src/memory_db.rs` | EVAL-023 (+0.137), EVAL-025 (-0.003), EVAL-026 (0% halluc cross-arch) | COVERED+VALIDATED |
| 5 | Memory | `src/memory_db.rs`, `src/memory_graph.rs`, `crates/mcp-servers/chump-mcp-adb`, **`src/reflection_db.rs::load_spawn_lessons` (MEM-006)** | none isolated; MEM-006 ships the spawn-time lesson loader; A/B validation deferred to MEM-006-VALIDATE follow-up | COVERED+UNTESTED |
| 6 | Reasoning | `src/reflection_db.rs`, `src/agent_loop/prompt_assembler.rs`, COG-016 directive | EVAL-023, EVAL-025, EVAL-026, EVAL-026b, EVAL-027b (n=50) + EVAL-027c (n=100 CONFIRMED) — **U-curve in directive effectiveness discovered, sonnet harm CONFIRMED at 33% (Δ +0.33 SIG)**, COG-016, COG-023 (Sonnet carve-out P1 ready to ship), COG-024 (default-OFF rethink) | COVERED+VALIDATED (with complexity) |
| 7 | Metacognition | `src/belief_state.rs`, `src/neuromodulation.rs`, `chump-neuromodulation` crate | EVAL-026 cross-architecture neuromod **harm** signal -0.10 to -0.16; individual modules (surprisal EMA, belief state) unablated — EVAL-043 pending | PARTIAL (net-negative signal; individual modules unablated — may need removal pending EVAL-043) |
| 8 | Executive Function | `src/agent_loop/`, `src/blackboard.rs`, `src/tool_middleware.rs`, `chump-coord` crate | none isolated | COVERED+UNTESTED |
| 9 | Problem Solving | `src/eval_harness.rs`, `crates/mcp-servers/chump-mcp-github`, tool dispatch | EVAL-023/025/026 measure problem-solving on hallucination tasks | COVERED+VALIDATED (narrow domain) |
| 10 | Social Cognition | `src/tool_middleware.rs` ASK_JEFF flow, `CHUMP_TOOLS_ASK` env var | none — never A/B tested | PARTIAL |

## Per-faculty notes

**1. Perception.** `chump-perception` crate handles inbound multi-modal extraction; Tavily MCP
server (`crates/mcp-servers/chump-mcp-tavily`) provides web-search perception. The EVAL-032
ablation flag (`CHUMP_BYPASS_PERCEPTION=1`) is now implemented in `src/env_flags.rs` and
`src/agent_loop/prompt_assembler.rs`, enabling isolation of the perception summary contribution
in A/B harness sweeps. No sweep results exist yet — the flag ships, the n=100 sweep is
pending. Status: COVERED+UNTESTED (ablation flag shipped, sweep pending).

**2. Generation.** `src/agent_loop/prompt_assembler.rs` shapes generation; EVAL-023 (n=600,
+0.137 hallucination delta) and EVAL-026 (n=900, 0% hallucination across Qwen-7B/235B + Llama-70B)
quantify output-quality changes attributable to prompt construction. Status: COVERED+VALIDATED.

**3. Attention. GAP (harness unblocked).** No Chump module implements selective attention or
distractor suppression. EVAL-028 (CatAttack adversarial-robustness probe) ran a pilot with
the new `--distractor` flag in `scripts/ab-harness/run-cloud-v2.py`, but execution was
truncated at n≤5 per condition — Wilson 95% CIs are >0.6 wide and overlap across both
the haiku-4-5 and Qwen2.5-7B arms, so no faculty-grade signal can be extracted yet (see
`CONSCIOUSNESS_AB_RESULTS.md` "EVAL-028" section). The harness change ships independently
so the full n=50 sweep can be re-run without further code work. Until that re-run lands,
this remains the **clearest single gap** in the faculty map and the top candidate for new
research investment.

**4. Learning.** `src/reflection_db.rs` (COG-016 lessons block, model-tier gating, reflection
writes) is the substrate for in-context learning. EVAL-023 validated lessons; EVAL-025 confirmed
the COG-016 anti-hallucination directive eliminates harm to -0.003; EVAL-026 confirmed
cross-architecture immunity. Status: COVERED+VALIDATED.

**5. Memory.** `src/memory_db.rs` (SQLite store) plus `src/memory_graph.rs` (entity-relation
graph) plus `chump-mcp-adb` (Android Debug Bridge memory adapter). Memory is used as fixture
state in EVAL-023/025 but recall accuracy itself is not isolated. Status: COVERED+UNTESTED —
needs a dedicated retrieval-precision eval.

**6. Reasoning. COVERED+VALIDATED — with documented complexity.** Deepest evidence base:
`src/reflection_db.rs` + `prompt_assembler.rs` + COG-016 directive. Validated by EVAL-023
(haiku-4-5 v1 +0.137 hallucination), EVAL-025 (directive neutralizes harm at haiku-4-5 →
-0.003), EVAL-026 (0% cross-arch on Qwen + Llama), EVAL-026b (Anthropic monotonic v1 harm
scaling: haiku-3 0% → haiku-4-5 +0.12 → sonnet-4-5 +0.16 directional → opus-4-5 +0.38 SIG),
EVAL-027b (cog016 directive at sonnet/opus n=50), and EVAL-027c which CONFIRMED the
EVAL-027b sonnet finding at n=100:

> **The cog016 anti-hallucination directive is NOT universally protective. It produces an
> inverted U-curve in effectiveness: works at small (haiku-4-5: +0.12 → -0.01) and large
> (opus-4-5: +0.38 → +0.10) tiers, but BACKFIRES at sonnet-4-5 (cog016 cell A 33% halluc
> vs cell B 0%, Δ +0.33 with non-overlapping CIs at n=100, inter-judge agreement 0.81).**

Production COG-016 currently ships with default Frontier-tier injection. Both sonnet-4-5
and opus-4-5 are classified Frontier in current ModelTier enum, so both receive cog016
lessons by default. **At sonnet-4-5 this produces 33% fake-tool emission per response —
actively harming production users right now.** COG-023 (Sonnet carve-out, P1) is the
defensive Path A patch ready to ship. COG-024 (default lessons-OFF, opt-in per model)
is the longer-term Path B rethink that questions whether ANY default-on lessons policy
is correct given cross-tier variability. The faculty remains COVERED+VALIDATED — we have
measured behavior across the full Anthropic capability range — but the protective
intervention is now documented as model-tier-specific rather than universal, AND a
defensive production patch is queued in the backlog.

**7. Metacognition. PARTIAL — net-negative signal (individual modules unablated).** `src/belief_state.rs` (probabilistic
state) and `src/neuromodulation.rs` / `chump-neuromodulation` crate implement self-monitoring
analogues. However EVAL-026's cross-architecture neuromod signal showed **harm** in the
-0.10 to -0.16 range across four models — current implementation may be a net loss. The
task-class-aware gating fix (EVAL-030) is shipped but not yet cross-validated. Neither belief
state nor surprisal EMA has been ablated in isolation; citing either as a validated contribution
is prohibited per `docs/RESEARCH_INTEGRITY.md` until EVAL-043 ships. **If EVAL-043 confirms net
harm for neuromodulation, this faculty row should be converted to a removal recommendation
rather than a research priority.** Do not continue shipping neuromod-dependent features until
EVAL-043 resolves the question.

**8. Executive Function.** `src/agent_loop/` (orchestration), `src/blackboard.rs` (multi-module
communication), `src/tool_middleware.rs` (tool dispatch), and `chump-coord` (multi-agent NATS
coordination, worktrees, leases, gap registry) cover planning, flexibility, and goal-directed
behavior. No isolated A/B evidence — all observed indirectly through reasoning evals. Status:
COVERED+UNTESTED.

**9. Problem Solving.** `src/eval_harness.rs` plus tool surface (`chump-mcp-github`,
`chump-mcp-tavily`, ASK_JEFF) defines the problem-solving loop. EVAL-023/025/026 measure
problem-solving on hallucination tasks specifically; broader domain coverage untested.
Status: COVERED+VALIDATED (narrow).

**10. Social Cognition. PARTIAL.** Tool-approval flow + ASK_JEFF (`CHUMP_TOOLS_ASK`) constitute
a minimal social-cognition surface — the agent recognizes when to defer to a human and asks.
Untested at scale; no eval measures appropriateness or calibration of the ask/don't-ask
decision. Candidate for a future EVAL.

## Headline coverage assessment

**4 of 10 faculties are COVERED+VALIDATED** with cited A/B evidence: Generation, Learning,
Reasoning, Problem Solving (narrow). All four ride on the same EVAL-023/025/026 evidence
stack — meaning Chump's empirical confidence is concentrated in the prompt-construction +
in-context-learning + reasoning loop. **4 of 10 are COVERED+UNTESTED** (Perception, Memory,
Executive Function, plus Social Cognition adjacent): modules exist and run in production but
no A/B harness isolates their contribution. **2 of 10 are GAP or net-negative**: Attention has
no module at all, and Metacognition's neuromodulation substrate showed measurable harm across
EVAL-026 (the only faculty where current evidence points to *removing* code rather than adding
eval coverage).

For 2026-Q3, this map argues for three concrete investments, in priority order: (1) ship
EVAL-028 (CatAttack) to put a first number on Attention; (2) ablate or redesign
`chump-neuromodulation` given the cross-architecture harm signal — don't keep building on a
substrate that loses in A/B; (3) build isolated retrieval-precision and tool-selection evals
to convert the four COVERED+UNTESTED rows into validated coverage. The reasoning stack is
already the strongest area — the marginal research dollar belongs elsewhere.

## Sources

- DeepMind framework: <https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf>
- A/B results stack: [`docs/CONSCIOUSNESS_AB_RESULTS.md`](./CONSCIOUSNESS_AB_RESULTS.md)
- Competitive positioning: [`docs/STRATEGY_VS_GOOSE.md`](./STRATEGY_VS_GOOSE.md)
- Open gap registry: [`docs/gaps.yaml`](./gaps.yaml) (search EVAL-028, COG-016, COG-020)
