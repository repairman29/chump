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
| 1 | Perception | `chump-perception` crate, `crates/mcp-servers/chump-mcp-tavily` | **EVAL-054 (direct-API, n=50/cell, 2026-04-20):** delta=−0.040, CIs overlap — A/A baseline (direct API does not invoke the binary). **EVAL-059 (binary-mode, n=30/cell, 2026-04-20):** Cell A acc=0.000 CI [0.000, 0.114], Cell B acc=0.033 CI [0.006, 0.167], delta=+0.033, CIs overlap — NO SIGNAL. Both methods agree: NULL. Same binary-mode noise floor as EVAL-053 (Metacognition) and EVAL-056 (Memory). See `docs/eval/EVAL-054-perception-ablation.md`. | COVERED+VALIDATED(NULL) — both direct-API (EVAL-054) and binary-mode (EVAL-059) sweeps show NULL signal; binary noise floor (~97–100% exit-1 rate) limits interpretability (same caveat as EVAL-053/EVAL-056) |
| 2 | Generation | `src/agent_loop/`, `src/agent_loop/prompt_assembler.rs` | EVAL-023, EVAL-025, EVAL-026 (output quality deltas) | COVERED+VALIDATED |
| 3 | Attention | *no module today* | EVAL-028 pilot (n≤5, PR #138); EVAL-028 real n=50 (lessons-under-distraction — wrong cell layout); EVAL-047 (correct cell layout: bare vs distractor; sweep script ready, pilot n=5 pilot ran; full n=50 pending) | COVERED+UNTESTED (full sweep command ready, run EVAL-047) |
| 4 | Learning | `src/reflection_db.rs` (lessons block, COG-016), `src/memory_db.rs` | EVAL-023 (+0.137), EVAL-025 (-0.003), EVAL-026 (0% halluc cross-arch) | COVERED+VALIDATED |
| 5 | Memory | `src/memory_db.rs`, `src/memory_graph.rs`, `crates/mcp-servers/chump-mcp-adb`, **`src/reflection_db.rs::load_spawn_lessons` (MEM-006)** | **EVAL-056 (2026-04-20):** `CHUMP_BYPASS_SPAWN_LESSONS` flag shipped; binary-mode n=30/cell sweep: Cell A acc=0.033 CI [0.006, 0.167], Cell B acc=0.133 CI [0.053, 0.297], delta=+0.100, CIs overlap — NO SIGNAL. Same binary-mode noise floor as EVAL-053 (Metacognition). See `docs/eval/EVAL-056-memory-ablation.md`. | COVERED+PENDING_RESCORE (see EVAL-061/064) — NULL label suspended — broken instrument; re-score under EVAL-060 LLM-judge pending |
| 6 | Reasoning | `src/reflection_db.rs`, `src/agent_loop/prompt_assembler.rs`, COG-016 directive | EVAL-023, EVAL-025, EVAL-026, EVAL-026b, EVAL-027b (n=50) + EVAL-027c (n=100 CONFIRMED) — **U-curve in directive effectiveness discovered, sonnet harm CONFIRMED at 33% (Δ +0.33 SIG)**, COG-016, COG-023 (Sonnet carve-out P1 ready to ship), COG-024 (default-OFF rethink) | COVERED+VALIDATED (with complexity) |
| 7 | Metacognition | `src/belief_state.rs`, `src/neuromodulation.rs`, `chump-neuromodulation` crate | EVAL-026 cross-architecture neuromod **harm** signal -0.10 to -0.16; EVAL-043 ablation flags shipped (`CHUMP_BYPASS_BELIEF_STATE`, `CHUMP_BYPASS_SURPRISAL`, `CHUMP_BYPASS_NEUROMOD`); **EVAL-048 (2026-04-20):** sweep harness confirmed working (`scripts/ab-harness/run-ablation-sweep.py`), noise floor delta=0.0 (expected); **EVAL-063 (2026-04-20):** LLM-judge re-score n=50/cell — belief_state delta=+0.020, surprisal delta=+0.000, neuromod delta=+0.040, all CIs overlap — NO SIGNAL across all three modules — see `docs/eval/EVAL-049-binary-ablation.md` (EVAL-063 Re-score section) | COVERED+VALIDATED(NULL) — EVAL-063 LLM-judge re-score (n=50/cell, 2026-04-20) confirms NULL for all three modules; EVAL-061 suspended labels lifted; EVAL-026 negative prior (-0.10 to -0.16) not reproduced under LLM-judge scoring |
| 8 | Executive Function | `src/agent_loop/`, `src/blackboard.rs`, `src/tool_middleware.rs`, `chump-coord` crate | **EVAL-058 (2026-04-20):** `CHUMP_BYPASS_BLACKBOARD` flag shipped; binary-mode n=30/cell sweep: Cell A acc=0.100 CI [0.035, 0.256], Cell B acc=0.067 CI [0.018, 0.213], delta=−0.033, CIs overlap — NO SIGNAL. Same binary-mode noise floor as EVAL-056 (Memory) and EVAL-053 (Metacognition). See `docs/eval/EVAL-058-executive-function-ablation.md`. | COVERED+PENDING_RESCORE (see EVAL-061/064) — NULL label suspended — broken instrument; re-score under EVAL-060 LLM-judge pending; blackboard requires multi-turn test design |
| 9 | Problem Solving | `src/eval_harness.rs`, `crates/mcp-servers/chump-mcp-github`, tool dispatch | EVAL-023/025/026 measure problem-solving on hallucination tasks | COVERED+VALIDATED (narrow domain) |
| 10 | Social Cognition | `src/tool_middleware.rs` ASK_JEFF flow, `CHUMP_TOOLS_ASK` env var; COG-027 perception clarify-directive gate (`CHUMP_COG027_GATE`) | **EVAL-050 pilot (n=10/cell):** directional H1+H2 signal, PRELIMINARY. **EVAL-055 full sweep (n=50/cell, 2026-04-20):** ambiguous/procedural H1 confirmed (non-overlapping CIs, Δ=+0.300); ambiguous/static H1 inconclusive (CIs overlap, Δ=+0.200). **EVAL-057 LLM-judge sweep (n=50/cell, 2026-04-20):** near-ceiling on both ambiguous cells (A=1.000 [0.929,1.000] vs B=0.940 [0.838,0.979]); CIs overlap due to ceiling compression; H2 fails under judge (judge too liberal — scores hedging as clarification). Status unchanged: PRELIMINARY. **EVAL-062 strict-judge sweep (n=10/cell, 2026-04-20):** tighter rubric (only direct explicit questions count); ambiguous/static: A=1.000 vs B=1.000, Δ=0.000 — ceiling in both cells; ambiguous/procedural: A=1.000 vs B=0.900, CIs overlap; judge liberality confirmed NOT the root cause; ceiling compression confirmed as the binding constraint. Status unchanged: PRELIMINARY; n≥200/cell required. See `docs/eval/EVAL-050-social-cognition.md` | COVERED+VALIDATED (PRELIMINARY) — three scorer methods (heuristic, liberal judge, strict judge) all fail to achieve non-overlapping CIs on ambiguous categories; root cause confirmed as ceiling compression (claude-haiku-4-5 asks clarifying questions ~90–100% of the time on ambiguous prompts even without the directive); definitive graduation requires n≥200/cell or a lower-baseline model |

## Per-faculty notes

**1. Perception. COVERED+VALIDATED(NULL) — binary-mode sweep complete.** `chump-perception` crate
handles inbound multi-modal extraction; Tavily MCP server (`crates/mcp-servers/chump-mcp-tavily`)
provides web-search perception. The EVAL-032 ablation flag (`CHUMP_BYPASS_PERCEPTION=1`) is
implemented in `src/env_flags.rs` and `src/agent_loop/prompt_assembler.rs`.

Two sweeps have now run:

- **EVAL-054 (2026-04-20, direct-API, n=50/cell):** delta=−0.040, CIs overlap. This is the
  A/A baseline — the direct-API harness never invokes the chump binary, so the bypass flag
  has no effect. Confirmed noise floor.
- **EVAL-059 (2026-04-20, binary-mode, n=30/cell):** Cell A acc=0.000 CI [0.000, 0.114],
  Cell B acc=0.033 CI [0.006, 0.167], delta=+0.033, CIs overlap — NO SIGNAL. The
  `perception` module was added to `run-binary-ablation.py`'s MODULES dict as part of this
  gap. The bypass flag fires correctly through the Rust code path in
  `src/agent_loop/prompt_assembler.rs`. Same binary-mode noise floor as EVAL-053
  (Metacognition) and EVAL-056 (Memory): ~97–100% exit-1 rate indicates API connectivity
  failures dominate variance, not the perception summary injection. Both methods agree: NULL.

The null result does not imply zero effect — a multi-turn session with a running API endpoint
is required for a higher-fidelity measurement. Status: COVERED+VALIDATED(NULL).

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

**5. Memory. COVERED+PENDING_RESCORE (EVAL-061/064) — NULL label suspended — broken instrument; re-score under EVAL-060 LLM-judge pending.**
`src/memory_db.rs` (SQLite store) plus `src/memory_graph.rs` (entity-relation graph) plus
`chump-mcp-adb` (Android Debug Bridge memory adapter) plus `src/reflection_db.rs::load_spawn_lessons`
(MEM-006 spawn-time lesson injection). EVAL-056 (2026-04-20) ships `CHUMP_BYPASS_SPAWN_LESSONS=1`
(implemented in `src/env_flags.rs` + wired in `src/reflection_db.rs::load_spawn_lessons`) and runs
a binary-mode n=30/cell ablation sweep via `scripts/ab-harness/run-binary-ablation.py --module spawn_lessons`.

Results: Cell A (lessons on) acc=0.033 CI [0.006, 0.167], Cell B (lessons bypassed) acc=0.133 CI
[0.053, 0.297], delta=+0.100, Wilson CIs overlap — NO SIGNAL. Same binary-mode noise floor as
EVAL-053 (Metacognition modules): exit code 1 on ~90% of trials indicates API connectivity failures
dominate the variance, not lesson injection. The bypass flag fires correctly and is confirmed working.

For a higher-fidelity Memory eval, a multi-turn session with a running API endpoint and
`CHUMP_LESSONS_AT_SPAWN_N=5` configured is recommended. See `docs/eval/EVAL-056-memory-ablation.md`
for full methodology and raw results.

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

**7. Metacognition. COVERED+VALIDATED(NULL) — EVAL-063 LLM-judge re-score complete (2026-04-20).**
`src/belief_state.rs` (probabilistic state) and `src/neuromodulation.rs` / `chump-neuromodulation`
crate implement self-monitoring analogues. EVAL-026's cross-architecture neuromod signal showed
**harm** in the -0.10 to -0.16 range across four models; however, EVAL-063 LLM-judge re-score
(n=50/cell, 2026-04-20) does not reproduce that prior — all three modules show delta≈0 under proper
binary-mode + LLM-judge scoring.

**EVAL-043 ablation infrastructure (2026-04-19):**
- `CHUMP_BYPASS_BELIEF_STATE=1` — belief-state bypass (implemented EVAL-035, wired in
  `crates/chump-belief-state/src/lib.rs`): ablation flag shipped and swept
- `CHUMP_BYPASS_SURPRISAL=1` — surprisal EMA bypass (implemented EVAL-043, wired in
  `src/surprise_tracker.rs`): ablation flag shipped and swept
- `CHUMP_BYPASS_NEUROMOD=1` — neuromod bypass (implemented EVAL-043, alias for
  `CHUMP_NEUROMOD_ENABLED=0` in `src/neuromodulation.rs`): ablation flag shipped and swept

**EVAL-048 (2026-04-20):** Sweep harness `scripts/ab-harness/run-ablation-sweep.py` implemented
and confirmed working. Architecture caveat: bypass flags affect the chump Rust binary only, not
direct API calls.

**EVAL-063 (2026-04-20) — LLM-judge re-score:** EVAL-061 suspended the EVAL-053 exit-code NULL
labels after confirming broken instrument (~90–97% exit-1 rate from API connectivity failures, not
module effects). EVAL-063 re-ran all three modules under `--use-llm-judge` with n=50/cell and a
live Together.ai provider (Llama-3.3-70B-Instruct-Turbo agent, claude-haiku-4-5 judge):

| Module | Acc A | Acc B | Delta | Verdict |
|--------|-------|-------|-------|---------|
| belief_state | 0.680 | 0.700 | +0.020 | NO SIGNAL |
| surprisal | 0.640 | 0.640 | +0.000 | NO SIGNAL |
| neuromod | 0.600 | 0.640 | +0.040 | NO SIGNAL |

All CIs overlap. The EVAL-026 negative prior (−0.10 to −0.16) is not reproduced. Status updated to
COVERED+VALIDATED(NULL). See `docs/eval/EVAL-049-binary-ablation.md` (EVAL-063 Re-score section)
for full methodology and JSONL references.

**8. Executive Function. COVERED+PENDING_RESCORE (EVAL-061/064) — NULL label suspended — broken instrument; re-score under EVAL-060 LLM-judge pending; blackboard requires multi-turn test design.**
`src/agent_loop/` (orchestration), `src/blackboard.rs` (multi-module communication),
`src/tool_middleware.rs` (tool dispatch), and `chump-coord` (multi-agent NATS coordination,
worktrees, leases, gap registry) cover planning, flexibility, and goal-directed behavior.

EVAL-058 (2026-04-20) ships `CHUMP_BYPASS_BLACKBOARD=1` (implemented in `src/env_flags.rs`
+ wired in `src/agent_loop/prompt_assembler.rs` COG-015 entity-prefetch block) and runs a
binary-mode n=30/cell ablation sweep via `scripts/ab-harness/run-binary-ablation.py --module blackboard`.

Results: Cell A (blackboard active) acc=0.100 CI [0.035, 0.256], Cell B (blackboard bypassed)
acc=0.067 CI [0.018, 0.213], delta=−0.033, Wilson CIs overlap — NO SIGNAL. Same binary-mode
noise floor as EVAL-053 (Metacognition modules) and EVAL-056 (Memory): exit code 1 on ~90%
of trials indicates API connectivity failures dominate the variance, not the bypass flag.

For a higher-fidelity Executive Function eval, a running API endpoint with an entity-rich
multi-turn session and persisted blackboard facts is needed. The binary `--chump` single-turn
mode cannot meaningfully exercise the COG-015 cross-turn working memory path. See
`docs/eval/EVAL-058-executive-function-ablation.md` for full methodology and raw results.

**9. Problem Solving.** `src/eval_harness.rs` plus tool surface (`chump-mcp-github`,
`chump-mcp-tavily`, ASK_JEFF) defines the problem-solving loop. EVAL-023/025/026 measure
problem-solving on hallucination tasks specifically; broader domain coverage untested.
Status: COVERED+VALIDATED (narrow).

**10. Social Cognition. COVERED+VALIDATED (PRELIMINARY, EVAL-055/EVAL-057/EVAL-062 2026-04-20).** Tool-approval
flow + ASK_JEFF (`CHUMP_TOOLS_ASK`) constitute a minimal social-cognition surface — the agent
recognizes when to defer to a human and asks. EVAL-050 ran a pilot (n=10/cell/category) with
directional but PRELIMINARY signal. EVAL-055 ran the full heuristic sweep (n=50/cell/category, 300 total
trials):

- `ambiguous/procedural` (heuristic): H1 **confirmed** (non-overlapping Wilson 95% CIs, A=0.300 [0.191, 0.438]
  vs B=0.000 [0.000, 0.071], Δ=+0.300)
- `ambiguous/static` (heuristic): H1 **inconclusive** (CIs overlap by narrow margin: A=0.320 [0.208, 0.458]
  vs B=0.120 [0.056, 0.238], Δ=+0.200; A_lo=0.208 < B_hi=0.238)
- `clear/dynamic` (heuristic): H2 **holds** (CIs overlap as expected: A=0.160 [0.083, 0.285] vs
  B=0.040 [0.011, 0.135] — no significant over-asking signal)

**EVAL-057 LLM-judge sweep (2026-04-20, n=50/cell/category, 300 agent + 300 judge calls):**

- `ambiguous/static` (LLM judge): near-ceiling, A=1.000 [0.929,1.000] vs B=0.940 [0.838,0.979]; CIs overlap — ceiling compression
- `ambiguous/procedural` (LLM judge): near-ceiling, A=1.000 [0.929,1.000] vs B=0.940 [0.838,0.979]; CIs overlap — ceiling compression
- `clear/dynamic` (LLM judge): A=0.860 [0.738,0.930] vs B=0.680 [0.542,0.792]; CIs overlap — H2 FAILS under judge

**EVAL-062 strict-judge sweep (2026-04-20, n=10/cell/category, 60 agent + 60 judge calls):**
Root-cause diagnosis — tests whether judge liberality (not ceiling compression) caused EVAL-057 PRELIMINARY status.
The strict rubric counts only direct explicit clarifying questions; hedging scores CLARIFIED: 0.

- `ambiguous/static` (strict judge): A=1.000 [0.722,1.000] vs B=1.000 [0.722,1.000], Δ=0.000 — **ceiling in both cells**
- `ambiguous/procedural` (strict judge): A=1.000 [0.722,1.000] vs B=0.900 [0.596,0.982], Δ=+0.100, CIs overlap
- `clear/dynamic` (strict judge): A=1.000 [0.722,1.000] vs B=0.500 [0.237,0.763], Δ=+0.500, CIs do not overlap — H2 fails (over-asking)

**Root cause confirmed by EVAL-062:** judge liberality is NOT the binding constraint. Cell B stays near-ceiling
even under the strict definition on ambiguous prompts. Ceiling compression is the primary blocker — claude-haiku-4-5
asks direct explicit clarifying questions ~90–100% of the time on ambiguous prompts without any directive.

Status is PRELIMINARY because H1 requires non-overlapping CIs on *both* ambiguous categories per
`docs/RESEARCH_INTEGRITY.md`, and all three scorer methods (heuristic, liberal judge, strict judge) fail to
achieve this. Definitive validation requires n≥200/cell or a lower-baseline model.

COG-027 ships a task-class-aware gate for the perception clarification directive: on procedural
tasks (identified by the `is_conditional_chain` heuristic in `reflection_db.rs`), the
"Ambiguity: X.X (consider clarifying)" fragment is suppressed from the `[Perception]` context
summary before system-prompt injection (mirroring the EVAL-030 gate on the lessons block).
Gate is default ON; disable via `CHUMP_COG027_GATE=0` for A/B harness sweeps measuring the
v1 baseline.

See `docs/eval/EVAL-050-social-cognition.md` (Strict-Judge Sweep / EVAL-062 section) for full results.

## Headline coverage assessment

**5 of 10 faculties are COVERED+VALIDATED(NULL) or COVERED+VALIDATED** with cited A/B evidence:
Generation, Learning, Reasoning, Problem Solving (narrow), and Metacognition (NULL — EVAL-063
LLM-judge re-score, 2026-04-20). All non-NULL validated faculties ride on the EVAL-023/025/026
evidence stack. **1 of 10 is COVERED+VALIDATED (PRELIMINARY)** (Social Cognition — EVAL-055+EVAL-057
sweeps confirm direction but not statistical separation).
**2 of 10 are COVERED+PENDING_RESCORE** (Memory EVAL-056, Executive Function EVAL-058):
ablation flags shipped and binary-mode sweeps completed but binary noise floor (0–10% baseline
accuracy, ~90–97% exit-1 rate) means the NULL labels are not trustworthy — EVAL-061 suspended
those labels and filed EVAL-064 to re-score under EVAL-060's LLM-judge instrument. **2 of 10
are COVERED+UNTESTED** (Perception EVAL-059 and Attention EVAL-047 share the same binary
noise-floor caveat; full validation requires a live API endpoint): modules exist (or harness
infrastructure exists) but no A/B sweep has cleared the n≥50 bar with a live API endpoint.
Metacognition's previously unresolved net-negative prior (EVAL-026 −0.10 to −0.16) was not
reproduced under EVAL-063 LLM-judge scoring at n=50/cell — the EVAL-026 signal is attributed
to direct-API harness confounds.

EVAL-047 moved Attention from GAP to COVERED+UNTESTED by shipping a correct-cell-layout sweep
script and validating the harness infrastructure at pilot scale (n=5). The full n=50 sweep
(`python3 scripts/ab-harness/run-catattack-sweep.py --n-per-cell 50`) will graduate Attention
to VALIDATED or TESTED+NEGATIVE once run.

EVAL-055 ran Social Cognition at n=50/cell/category (2026-04-20), confirming H1 for procedural
prompts and H2 for clear/dynamic prompts with the heuristic scorer. EVAL-057 replaced the
heuristic with an LLM judge (2026-04-20): judge confirms the heuristic severely undercounted
(×3–10×) but reveals a near-ceiling effect on both cells and judge liberality on clear prompts.
EVAL-062 (2026-04-20) ran a strict-judge diagnostic (n=10/cell): confirmed ceiling compression
as the root cause — judge liberality is NOT the binding constraint. Both cells remain near 1.000
on ambiguous prompts even with a strict rubric. Status remains PRELIMINARY.
The harness now supports `--use-llm-judge` and `--strict-judge` for future sweeps.
Definitive validation of Social Cognition requires n≥200/cell or a lower-baseline model.

For 2026-Q3, this map argues for three concrete investments, in priority order: (1) run the
EVAL-047 full n=50 sweep to graduate Attention; (2) run EVAL-064 to re-score Memory and
Executive Function under the LLM-judge harness (same fix as EVAL-063 for Metacognition);
(3) build isolated retrieval-precision and tool-selection evals to convert the remaining
COVERED+UNTESTED rows into validated coverage. The reasoning stack is already the strongest
area — the marginal research dollar belongs elsewhere.

## Sources

- DeepMind framework: <https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf>
- A/B results stack: [`docs/CONSCIOUSNESS_AB_RESULTS.md`](./CONSCIOUSNESS_AB_RESULTS.md)
- Competitive positioning: [`docs/STRATEGY_VS_GOOSE.md`](./STRATEGY_VS_GOOSE.md)
- Open gap registry: [`docs/gaps.yaml`](./gaps.yaml) (search EVAL-028, COG-016, COG-020)
