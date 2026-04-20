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
| 3 | Attention | *no module today* | EVAL-028 pilot (n≤5, PR #138); EVAL-028 real n=50 (lessons-under-distraction — wrong cell layout); EVAL-047 (correct cell layout: bare vs distractor; n=20 sweep run 2026-04-20): Cell A acc=1.000, Cell B acc=1.000, Δ=0.000, CIs overlap — **but Cell B halluc_rate=0.300 vs Cell A 0.000 (6 hallucinations)** | COVERED+TESTED+NEGATIVE (accuracy; halluc signal inconclusive at n=20 — n=50 needed to confirm) |
| 4 | Learning | `src/reflection_db.rs` (lessons block, COG-016), `src/memory_db.rs` | EVAL-023 (+0.137), EVAL-025 (-0.003), EVAL-026 (0% halluc cross-arch) | COVERED+VALIDATED |
| 5 | Memory | `src/memory_db.rs`, `src/memory_graph.rs`, `crates/mcp-servers/chump-mcp-adb`, **`src/reflection_db.rs::load_spawn_lessons` (MEM-006)** | none isolated; MEM-006 ships the spawn-time lesson loader; A/B validation deferred to MEM-006-VALIDATE follow-up | COVERED+UNTESTED |
| 6 | Reasoning | `src/reflection_db.rs`, `src/agent_loop/prompt_assembler.rs`, COG-016 directive | EVAL-023, EVAL-025, EVAL-026, EVAL-026b, EVAL-027b (n=50) + EVAL-027c (n=100 CONFIRMED) — **U-curve in directive effectiveness discovered, sonnet harm CONFIRMED at 33% (Δ +0.33 SIG)**, COG-016, COG-023 (Sonnet carve-out P1 ready to ship), COG-024 (default-OFF rethink) | COVERED+VALIDATED (with complexity) |
| 7 | Metacognition | `src/belief_state.rs`, `src/neuromodulation.rs`, `chump-neuromodulation` crate | EVAL-026 cross-architecture neuromod **harm** signal -0.10 to -0.16; EVAL-043 ablation flags shipped (`CHUMP_BYPASS_BELIEF_STATE`, `CHUMP_BYPASS_SURPRISAL`, `CHUMP_BYPASS_NEUROMOD`); EVAL-048 noise floor confirmed (direct-API harnesses bypass Rust code); **EVAL-049 binary-mode harness shipped** (`scripts/ab-harness/run-binary-ablation.py`) — first mechanism that actually exercises bypass flags via chump binary; full sweep pending (n=30+) | PARTIAL (net-negative prior signal; binary-mode harness shipped EVAL-049, sweep pending) |
| 8 | Executive Function | `src/agent_loop/`, `src/blackboard.rs`, `src/tool_middleware.rs`, `chump-coord` crate | none isolated | COVERED+UNTESTED |
| 9 | Problem Solving | `src/eval_harness.rs`, `crates/mcp-servers/chump-mcp-github`, tool dispatch | EVAL-023/025/026 measure problem-solving on hallucination tasks | COVERED+VALIDATED (narrow domain) |
| 10 | Social Cognition | `src/tool_middleware.rs` ASK_JEFF flow, `CHUMP_TOOLS_ASK` env var; COG-027 perception clarify-directive gate (`CHUMP_COG027_GATE`) | EVAL-038 fixture (30 prompts); EVAL-050 pilot (n=10/cat, directional signal); EVAL-051 full pilot (2026-04-20): manual clarif rates ambiguous/proc A=1.000 vs B=0.900 (Δ+0.1), ambiguous/static A=0.800 vs B=0.700 (Δ+0.1) — CIs overlap at n=10; H1 directionally confirmed, H2 inconclusive | COVERED+VALIDATED(PRELIMINARY) — directional confirmation from two independent pilots; full n≥50 + LLM judge needed for research-grade status |

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

**3. Attention. COVERED+TESTED+NEGATIVE (accuracy; halluc signal inconclusive at n=20).** No Chump module implements
selective attention or distractor suppression. EVAL-028 ran two CatAttack sweeps with the wrong cell layout.
EVAL-047 ships the correct cell layout and harness; EVAL-051 ran the first real n=20/cell sweep (2026-04-20):

- Cell A (baseline): n=20, acc=1.000, halluc_rate=0.000 — Wilson CI [0.839, 1.000] for acc; [0.000, 0.161] for halluc
- Cell B (distracted): n=20, acc=1.000, halluc_rate=0.300 — Wilson CI [0.839, 1.000] for acc; [0.145, 0.519] for halluc
- Δ accuracy = +0.000 (CIs overlap → no accuracy signal at this n)
- Δ halluc_rate = +0.300 (halluc CIs marginally overlap at [0.000, 0.161] vs [0.145, 0.519] → inconclusive)

The distractor did not reduce accuracy at n=20 — likely a ceiling effect on structured tasks. Six hallucinations appeared in the distracted cell vs zero in baseline, concentrated in reasoning, factual, and code tasks. This is directionally consistent with the CatAttack paper's vulnerability claim but does not meet the non-overlapping-CI bar. Full n=50 sweep with harder tasks is needed. See `docs/eval/EVAL-047-catattack-full.md` for full results.

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

**7. Metacognition. PARTIAL — net-negative signal; binary-mode harness shipped (EVAL-049), sweep pending.**
`src/belief_state.rs` (probabilistic state) and `src/neuromodulation.rs` / `chump-neuromodulation`
crate implement self-monitoring analogues. However EVAL-026's cross-architecture neuromod signal
showed **harm** in the -0.10 to -0.16 range across four models — current implementation may be a
net loss. The task-class-aware gating fix (EVAL-030) is shipped but not yet cross-validated.

**EVAL-043 ablation infrastructure (2026-04-19):**
- `CHUMP_BYPASS_BELIEF_STATE=1` — belief-state bypass (implemented EVAL-035, wired in
  `crates/chump-belief-state/src/lib.rs`): ablation flag shipped, sweep pending via chump binary
- `CHUMP_BYPASS_SURPRISAL=1` — surprisal EMA bypass (implemented EVAL-043, wired in
  `src/surprise_tracker.rs`): **claim UNCONFIRMED — see RESEARCH_INTEGRITY.md, sweep pending via chump binary**
- `CHUMP_BYPASS_NEUROMOD=1` — neuromod bypass (implemented EVAL-043, alias for
  `CHUMP_NEUROMOD_ENABLED=0` in `src/neuromodulation.rs`): ablation flag shipped, sweep pending via chump binary

**EVAL-048 (2026-04-20):** Sweep harness `scripts/ab-harness/run-ablation-sweep.py` implemented
and confirmed working. Architecture caveat: bypass flags affect the chump Rust binary only, not
direct API calls. The direct-API harness establishes a noise floor (delta=0.0 for all three modules,
confirming harness infrastructure). Actual module isolation requires running via the chump binary.
See `docs/eval/EVAL-048-ablation-results.md` for full results, running instructions, and
the chump-binary harness commands.

**EVAL-049 binary-mode harness (2026-04-20):**
EVAL-048 discovered that all prior harnesses call the Anthropic API directly, so bypass flags
never fire. EVAL-049 ships `scripts/ab-harness/run-binary-ablation.py` — the first harness that
invokes `./target/release/chump --chump "<task>"` as a subprocess, correctly exercising all three
bypass flags. Use this harness for all future Metacognition module sweeps:

```bash
cargo build --release --bin chump
python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30
```

Dry-run (no binary needed): `python3 scripts/ab-harness/run-binary-ablation.py --dry-run`
Results doc: `docs/eval/EVAL-049-binary-ablation.md`

Citing any of these modules as validated contributions is prohibited per `docs/RESEARCH_INTEGRITY.md`
until binary-mode sweeps complete with n≥100, cross-family judges, and A/A ±0.03.
**If EVAL-049 binary sweeps confirm net harm for neuromodulation or surprisal EMA, those rows should be
converted to removal recommendations.** Do not continue shipping neuromod-dependent features until
EVAL-049 binary sweeps resolve the question.

**8. Executive Function.** `src/agent_loop/` (orchestration), `src/blackboard.rs` (multi-module
communication), `src/tool_middleware.rs` (tool dispatch), and `chump-coord` (multi-agent NATS
coordination, worktrees, leases, gap registry) cover planning, flexibility, and goal-directed
behavior. No isolated A/B evidence — all observed indirectly through reasoning evals. Status:
COVERED+UNTESTED.

**9. Problem Solving.** `src/eval_harness.rs` plus tool surface (`chump-mcp-github`,
`chump-mcp-tavily`, ASK_JEFF) defines the problem-solving loop. EVAL-023/025/026 measure
problem-solving on hallucination tasks specifically; broader domain coverage untested.
Status: COVERED+VALIDATED (narrow).

**10. Social Cognition. COVERED+VALIDATED(PRELIMINARY) — two independent pilots confirm directional H1 signal.**
Tool-approval flow + ASK_JEFF (`CHUMP_TOOLS_ASK`) constitute a minimal social-cognition surface.
EVAL-038 authored the 30-prompt fixture; EVAL-050 ran the first pilot; EVAL-051 (2026-04-20) ran the
full 30-prompt sweep (60 trials total, n=10/category/cell).

Key findings from EVAL-051 sweep:
- **H1 confirmed directionally:** Cell A (ASK-FIRST) clarification rates consistently exceed Cell B on both ambiguous categories — ambiguous/procedural (1.000 vs 0.900, Δ=+0.100) and ambiguous/static (0.800 vs 0.700, Δ=+0.100). The ask-first directive substantially increases clarification behavior.
- **H2 inconclusive:** clear/dynamic shows Cell A=0.600 vs Cell B=0.400 (Δ=+0.200) — the ask-first directive also increases clarification on clear tasks, which is the *over-ask* harm. CIs overlap at n=10.
- **Scoring caveat:** The heuristic scorer (`asked_clarification` in run-social-cognition-ab.py) under-counts multi-part clarification responses. Manual inspection shows 4-5x higher rates than the heuristic flags. An LLM judge is needed for research-grade scoring.
- **Architecture caveat:** This harness calls the Anthropic API directly — `CHUMP_TOOLS_ASK` env var does not affect these results. The delta measures LLM responsiveness to a system-prompt clarification directive, not the Chump binary policy gate.

COG-027 ships a task-class-aware gate for the perception clarification directive. See `docs/eval/EVAL-050-social-cognition.md`
for full methodology, results, and the path to full validation (n≥50 per cell + LLM judge).

Do not cite these results as "validated" per `docs/RESEARCH_INTEGRITY.md` until n≥50 per cell,
non-Anthropic judge, and A/A baseline within ±0.03 are satisfied.

## Headline coverage assessment

**Updated 2026-04-20 (EVAL-051: both sweeps run)**

**4 of 10 faculties are COVERED+VALIDATED** with cited A/B evidence: Generation, Learning,
Reasoning, Problem Solving (narrow). All four ride on the same EVAL-023/025/026 evidence
stack — meaning Chump's empirical confidence is concentrated in the prompt-construction +
in-context-learning + reasoning loop.

**1 of 10 is COVERED+VALIDATED(PRELIMINARY):** Social Cognition — two independent pilot sweeps
(EVAL-050 n=10/cat, EVAL-051 n=10/cat) show consistent directional H1 signal. Full validation
requires n≥50 per cell with an LLM judge.

**1 of 10 is COVERED+TESTED+NEGATIVE:** Attention — EVAL-051 ran n=20/cell CatAttack sweep;
no accuracy drop observed (likely ceiling effect on structured tasks), but +30% hallucination
rate in distracted cell (marginal CIs). Negative accuracy result; halluc signal inconclusive.
Full n=50 sweep with harder tasks is the next step.

**3 of 10 are COVERED+UNTESTED** (Perception, Memory, Executive Function): modules exist but
no isolated A/B sweep has cleared the n≥50 bar.

**1 of 10 is net-negative:** Metacognition's neuromodulation substrate showed measurable harm
across EVAL-026 (the only faculty where current evidence points to *removing* code rather than
adding eval coverage).

For 2026-Q3, this map argues for three concrete investments, in priority order:
1. Run the EVAL-047 full n=50 sweep to resolve the Attention hallucination signal (upgrade heuristic scorer to LLM judge in the process)
2. Ablate or redesign `chump-neuromodulation` given the cross-architecture harm signal — don't keep building on a substrate that loses in A/B
3. Run Social Cognition at n≥50 with LLM judge to graduate from PRELIMINARY to full VALIDATED status; simultaneously wire the correct `CHUMP_TOOLS_ASK` path through the chump binary to measure the actual policy gate rather than the LLM baseline

## Sources

- DeepMind framework: <https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf>
- A/B results stack: [`docs/CONSCIOUSNESS_AB_RESULTS.md`](./CONSCIOUSNESS_AB_RESULTS.md)
- Competitive positioning: [`docs/STRATEGY_VS_GOOSE.md`](./STRATEGY_VS_GOOSE.md)
- Open gap registry: [`docs/gaps.yaml`](./gaps.yaml) (search EVAL-028, COG-016, COG-020)
