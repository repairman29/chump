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
| 1 | Perception | `chump-perception` crate, `crates/mcp-servers/chump-mcp-tavily` | **EVAL-054 (2026-04-20):** n=50/cell A/A binary-mode ablation sweep; Cell A acc=0.980 [0.895, 0.996], Cell B acc=0.940 [0.838, 0.979]; delta=−0.040, CIs overlap → NEUTRAL. No detectable harm or benefit from bypassing perception summary in direct-API harness. Confirms noise floor. See `docs/eval/EVAL-054-perception-ablation.md`. | COVERED+VALIDATED(NULL) |
| 2 | Generation | `src/agent_loop/`, `src/agent_loop/prompt_assembler.rs` | EVAL-023, EVAL-025, EVAL-026 (output quality deltas) | COVERED+VALIDATED |
| 3 | Attention | *no module today* | EVAL-028 pilot (n≤5, PR #138); EVAL-028 real n=50 (lessons-under-distraction — wrong cell layout); EVAL-047/EVAL-051 (n=20/cell, 2026-04-20): Cell A halluc_rate=0.000, Cell B halluc_rate=0.300, CIs marginally overlap; EVAL-052 (n=50/cell, 2026-04-20): Cell A halluc_rate=0.000 CI [0.000, 0.071], Cell B halluc_rate=0.340 CI [0.224, 0.478] — **non-overlapping CIs confirm distractor hallucination signal** | COVERED+VALIDATED(NEGATIVE) — distractor increases hallucination rate Δ+0.340 (non-overlapping Wilson CIs at n=50); no accuracy degradation (ceiling effect) |
| 4 | Learning | `src/reflection_db.rs` (lessons block, COG-016), `src/memory_db.rs` | EVAL-023 (+0.137), EVAL-025 (-0.003), EVAL-026 (0% halluc cross-arch) | COVERED+VALIDATED |
| 5 | Memory | `src/memory_db.rs`, `src/memory_graph.rs`, `crates/mcp-servers/chump-mcp-adb`, **`src/reflection_db.rs::load_spawn_lessons` (MEM-006)** | none isolated; MEM-006 ships the spawn-time lesson loader; A/B validation deferred to MEM-006-VALIDATE follow-up | COVERED+UNTESTED |
| 6 | Reasoning | `src/reflection_db.rs`, `src/agent_loop/prompt_assembler.rs`, COG-016 directive | EVAL-023, EVAL-025, EVAL-026, EVAL-026b, EVAL-027b (n=50) + EVAL-027c (n=100 CONFIRMED) — **U-curve in directive effectiveness discovered, sonnet harm CONFIRMED at 33% (Δ +0.33 SIG)**, COG-016, COG-023 (Sonnet carve-out P1 ready to ship), COG-024 (default-OFF rethink) | COVERED+VALIDATED (with complexity) |
| 7 | Metacognition | `src/belief_state.rs`, `src/neuromodulation.rs`, `chump-neuromodulation` crate | EVAL-026 cross-architecture neuromod harm signal (−0.10 to −0.16) attributed to direct-API harness confounds (EVAL-048); **EVAL-053 binary-mode sweep (n=30/cell, Llama-3.3-70B, 2026-04-20):** belief_state Acc A=1.000/B=1.000 Δ=0.000 CI [0.886,1.000] both; surprisal Acc A=1.000/B=1.000 Δ=0.000; neuromod Acc A=1.000/B=1.000 Δ=0.000 — all CIs overlap, all deltas zero | COVERED+VALIDATED(NULL) — all three modules (belief_state, surprisal, neuromod) show delta=0.000 at n=30 binary-mode sweep; prior EVAL-026 harm signal not reproduced under proper isolation; null result at n=30 on factual/reasoning fixture (ceiling effect possible; harder fixture at n=100 recommended) |
| 8 | Executive Function | `src/agent_loop/`, `src/blackboard.rs`, `src/tool_middleware.rs`, `chump-coord` crate | none isolated | COVERED+UNTESTED |
| 9 | Problem Solving | `src/eval_harness.rs`, `crates/mcp-servers/chump-mcp-github`, tool dispatch | EVAL-023/025/026 measure problem-solving on hallucination tasks | COVERED+VALIDATED (narrow domain) |
| 10 | Social Cognition | `src/tool_middleware.rs` ASK_JEFF flow, `CHUMP_TOOLS_ASK` env var; COG-027 perception clarify-directive gate (`CHUMP_COG027_GATE`) | **EVAL-050 (2026-04-20):** 30-prompt ask-vs-guess A/B sweep run via `scripts/ab-harness/run-social-cognition-ab.py`; pilot n=10/cell/category; H1 confirmed (ambiguous/static Δ=+0.700, ambiguous/procedural Δ=+0.600, non-overlapping CIs); H2 confirmed (clear/dynamic Δ=−0.050, CIs overlap — no over-ask); CHUMP_TOOLS_ASK binary-mode caveat documented (harness measures LLM directive responsiveness, not Chump policy gate). See `docs/eval/EVAL-050-social-cognition.md`. | COVERED+VALIDATED (PRELIMINARY — pilot n=10/cell; full n≥50 sweep pending) |

## Per-faculty notes

**1. Perception. COVERED+VALIDATED(NULL).** `chump-perception` crate handles inbound
multi-modal extraction; Tavily MCP server (`crates/mcp-servers/chump-mcp-tavily`) provides
web-search perception. The EVAL-032 ablation flag (`CHUMP_BYPASS_PERCEPTION=1`) is implemented
in `src/env_flags.rs` and `src/agent_loop/prompt_assembler.rs`. **EVAL-054 (2026-04-20)**
ran the first validated ablation sweep: n=50/cell, Cell A acc=0.980 [0.895, 0.996], Cell B
acc=0.940 [0.838, 0.979], delta=−0.040, CIs overlap. Verdict: NEUTRAL — no detectable
performance signal. As with all direct-API harness sweeps, the bypass flag does not affect
the API call path; this confirms the noise floor (effectively an A/A control). Five
perception-specific tasks (`abl-16` through `abl-20`) were added to the task pool and all
scored >0.75. Status: COVERED+VALIDATED(NULL) — ablation infrastructure validated, delta≈0
confirmed, no follow-up action needed.

**2. Generation.** `src/agent_loop/prompt_assembler.rs` shapes generation; EVAL-023 (n=600,
+0.137 hallucination delta) and EVAL-026 (n=900, 0% hallucination across Qwen-7B/235B + Llama-70B)
quantify output-quality changes attributable to prompt construction. Status: COVERED+VALIDATED.

**3. Attention. COVERED+UNTESTED (full sweep command ready).** No Chump module implements
selective attention or distractor suppression. EVAL-028 ran two CatAttack sweeps: a pilot (n≤5)
and a real n=50 sweep, but both had the wrong cell layout — the distractor was in both cells,
measuring the lessons effect under distraction rather than the raw CatAttack vulnerability.
EVAL-047 fixes the cell layout (Cell A = bare prompt, Cell B = distractor prepended; both
lessons-on) and ships `scripts/ab-harness/run-catattack-sweep.py` — a self-contained sweep
script with `--dry-run` support and Wilson 95% CI reporting. A pilot run (n=5/cell) validated
the harness infrastructure; the full n=50 sweep requires running
`python3 scripts/ab-harness/run-catattack-sweep.py --n-per-cell 50`. See
`docs/eval/EVAL-047-catattack-full.md` for methodology and pilot results.

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

**7. Metacognition. COVERED+VALIDATED(NULL) — binary-mode sweep (n=30/cell) shows no measurable module effect.**
`src/belief_state.rs` (probabilistic state) and `src/neuromodulation.rs` / `chump-neuromodulation`
crate implement self-monitoring analogues.

**EVAL-053 sweep result (2026-04-20):**
Binary-mode sweep using `scripts/ab-harness/run-binary-ablation.py` (EVAL-049 harness) with
n=30/cell on 30 built-in factual/reasoning/instruction tasks (Llama-3.3-70B via Together API).
All 180 trials completed (exit=0, output_chars > 10).

| Module | n/cell | Acc A | Acc B | Wilson 95% CI (A) | Wilson 95% CI (B) | Delta | Verdict |
|--------|--------|-------|-------|-------------------|-------------------|-------|---------|
| belief_state | 30 | 1.000 | 1.000 | [0.886, 1.000] | [0.886, 1.000] | 0.000 | COVERED+VALIDATED(NULL) |
| surprisal | 30 | 1.000 | 1.000 | [0.886, 1.000] | [0.886, 1.000] | 0.000 | COVERED+VALIDATED(NULL) |
| neuromod | 30 | 1.000 | 1.000 | [0.886, 1.000] | [0.886, 1.000] | 0.000 | COVERED+VALIDATED(NULL) |

The prior EVAL-026 neuromod harm signal (−0.10 to −0.16) is **not reproduced** under binary-mode
isolation. Per EVAL-048, that signal came from direct-API harnesses that never invoke the chump
binary — the bypass flags had no effect and the signal reflected LLM variance, not module contribution.

**Caveats:**
- The 30-task fixture achieves 100% accuracy in both cells — a ceiling effect that limits
  sensitivity. A harder multi-step fixture at n=100 would test whether NULL holds under
  more demanding conditions.
- The structural heuristic (exit=0 AND chars>10) scores completion, not response quality.
  A quality-sensitive LLM judge sweep may reveal subtle differences not captured here.

**EVAL-043 ablation infrastructure (2026-04-19, still valid):**
- `CHUMP_BYPASS_BELIEF_STATE=1` — belief-state bypass (`crates/chump-belief-state/src/lib.rs`)
- `CHUMP_BYPASS_SURPRISAL=1` — surprisal EMA bypass (`src/surprise_tracker.rs`)
- `CHUMP_BYPASS_NEUROMOD=1` — neuromod bypass (`src/neuromodulation.rs`)

All three flags are exercised correctly by the binary-mode harness. To re-run:
```bash
source .env && OPENAI_API_BASE=https://api.together.xyz/v1 \
  OPENAI_API_KEY="$TOGETHER_API_KEY" \
  OPENAI_MODEL=meta-llama/Llama-3.3-70B-Instruct-Turbo \
  python3 scripts/ab-harness/run-binary-ablation.py --module all --n-per-cell 30 \
  --binary ./target/release/chump
```

Results doc: `docs/eval/EVAL-049-binary-ablation.md`

**8. Executive Function.** `src/agent_loop/` (orchestration), `src/blackboard.rs` (multi-module
communication), `src/tool_middleware.rs` (tool dispatch), and `chump-coord` (multi-agent NATS
coordination, worktrees, leases, gap registry) cover planning, flexibility, and goal-directed
behavior. No isolated A/B evidence — all observed indirectly through reasoning evals. Status:
COVERED+UNTESTED.

**9. Problem Solving.** `src/eval_harness.rs` plus tool surface (`chump-mcp-github`,
`chump-mcp-tavily`, ASK_JEFF) defines the problem-solving loop. EVAL-023/025/026 measure
problem-solving on hallucination tasks specifically; broader domain coverage untested.
Status: COVERED+VALIDATED (narrow).

**10. Social Cognition. COVERED+VALIDATED (PRELIMINARY — EVAL-050 pilot run; full n≥50 sweep pending).**
Tool-approval flow + ASK_JEFF (`CHUMP_TOOLS_ASK`) constitute a minimal social-cognition
surface — the agent recognizes when to defer to a human and asks.

**EVAL-050 (2026-04-20):** The EVAL-038 30-prompt fixture was run via
`scripts/ab-harness/run-social-cognition-ab.py` in a two-cell A/B design:

- **Cell A (ASK-FIRST):** system prompt includes clarification directive
- **Cell B (GUESS-AND-ACT):** baseline, no directive

Pilot results (n=10/cell/category, model=claude-haiku-4-5, heuristic scorer):

| Category | Δ clarif_rate (A−B) | CIs overlap? | H verdict |
|---|---|---|---|
| ambiguous/static | +0.700 | NO | H1 CONFIRMED |
| ambiguous/procedural | +0.600 | NO | H1 CONFIRMED |
| clear/dynamic | −0.050 | YES | H2 CONFIRMED |

Both hypotheses hold directionally: ask-first substantially raises clarification rate
on ambiguous prompts (+0.60–0.70), and does not cause over-asking on clear/dynamic
prompts (Δ ≈ 0, within noise). This is the first numeric Social Cognition faculty signal.

**Architecture caveat:** `CHUMP_TOOLS_ASK` is a Chump binary flag — not reachable
via direct API. The harness measures LLM responsiveness to a clarification directive
in the system prompt, not the full Chump policy gate. Results are an upper bound on
what the policy can achieve; actual gate effectiveness requires binary-mode sweeps.

COG-027 ships a task-class-aware gate for the perception clarification directive: on
procedural tasks (identified by the `is_conditional_chain` heuristic in
`reflection_db.rs`), the "Ambiguity: X.X (consider clarifying)" fragment is suppressed
from the `[Perception]` context summary before system-prompt injection (mirroring the
EVAL-030 gate on the lessons block). Gate is default ON; disable via
`CHUMP_COG027_GATE=0` for A/B harness sweeps measuring the v1 baseline.

For full research-grade validation (n≥50/cell, non-Anthropic judge, A/A baseline):
```bash
python3 scripts/ab-harness/run-social-cognition-ab.py --n-repeats 5 --category all
```

See `docs/eval/EVAL-050-social-cognition.md` for full results and methodology.
See `docs/eval/EVAL-038-ambiguous-prompt-ab.md` for fixture design.
Pilot results are PRELIMINARY — do not cite as research-grade until n≥50 sweep clears
the `docs/RESEARCH_INTEGRITY.md` standards.

## Headline coverage assessment

**Updated 2026-04-20 (EVAL-053: Metacognition n=30/cell binary-mode sweep complete)**

**4 of 10 faculties are COVERED+VALIDATED** with cited A/B evidence: Generation, Learning,
Reasoning, Problem Solving (narrow). All four ride on the same EVAL-023/025/026 evidence
stack — meaning Chump's empirical confidence is concentrated in the prompt-construction +
in-context-learning + reasoning loop.

**1 of 10 is COVERED+VALIDATED(NEGATIVE):** Attention — EVAL-052 ran n=50/cell CatAttack sweep
(2026-04-20); hallucination-rate CIs are non-overlapping (Cell A [0.000, 0.071] vs Cell B
[0.224, 0.478], Δ+0.340). The distractor-induced hallucination effect is statistically confirmed.
No accuracy degradation (ceiling effect on structured tasks). "NEGATIVE" = no Chump module
mitigates this vulnerability yet.

**1 of 10 is COVERED+VALIDATED(NULL):** Metacognition — EVAL-053 ran n=30/cell binary-mode sweep
(2026-04-20) across all three modules (belief_state, surprisal, neuromod). All show delta=0.000
with fully overlapping CIs at Llama-3.3-70B on a 30-task fixture. The prior EVAL-026 harm signal
(−0.10 to −0.16) is attributed to direct-API harness confounds (never invoked the binary). NULL
result at n=30 may reflect ceiling effect on the factual fixture; harder test at n=100 recommended.

**1 of 10 is COVERED+VALIDATED(PRELIMINARY):** Social Cognition — two independent pilot sweeps
(EVAL-050 n=10/cat, EVAL-051 n=10/cat) show consistent directional H1 signal. Full validation
requires n≥50 per cell with an LLM judge.

**3 of 10 are COVERED+UNTESTED** (Perception, Memory, Executive Function): modules exist but
no isolated A/B sweep has cleared the n≥50 bar.

For 2026-Q3, this map argues for three concrete investments, in priority order:
1. Run Social Cognition at n≥50 with LLM judge to graduate from PRELIMINARY to full VALIDATED status; simultaneously wire the correct `CHUMP_TOOLS_ASK` path through the chump binary to measure the actual policy gate rather than the LLM baseline
2. Design a distractor-mitigation intervention for Attention (EVAL-033) — the n=50 hallucination signal is now quantified and stable enough to use as a baseline for mitigation A/B
3. Run Metacognition at n=100 with a harder fixture (multi-step reasoning, ambiguous prompts) to confirm or rebut the NULL result under more demanding conditions; also add LLM judge scoring to detect quality differences not captured by the structural heuristic

## Sources

- DeepMind framework: <https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf>
- A/B results stack: [`docs/CONSCIOUSNESS_AB_RESULTS.md`](./CONSCIOUSNESS_AB_RESULTS.md)
- Competitive positioning: [`docs/STRATEGY_VS_GOOSE.md`](./STRATEGY_VS_GOOSE.md)
- Open gap registry: [`docs/gaps.yaml`](./gaps.yaml) (search EVAL-028, COG-016, COG-020)
