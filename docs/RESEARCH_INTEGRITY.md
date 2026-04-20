# Research Integrity Directive
> **Binding for all agents:** Claude Code, Cursor, Chump-orchestrator, and any other automated or
> human contributor. Read this before touching any eval, research claim, or documentation that
> references Chump's cognitive-architecture findings.
>
> Last updated: 2026-04-19. Supersedes any earlier research framing in CHUMP_PROJECT_BRIEF.md,
> CHUMP_RESEARCH_BRIEF.md, or CONSCIOUSNESS_AB_RESULTS.md where those docs conflict with
> this directive.

---

## The Accurate Thesis

**What the evidence supports:**

> Instruction injection at inference time has systematically different effects by model tier and
> task class. Prescriptive directives (lessons blocks, neuromodulation hints) improve task
> performance on small models (haiku-4-5) on specific task types (reflection, perception), but
> actively harm performance on frontier models (sonnet-4-5+) — confirmed at n=100 with
> cross-family validation. The harm mechanisms are diagnosable: conditional-chain dilution and
> trivial-token contamination.

**What the evidence does NOT support:**

- "Cognitive architecture improves agent performance" — the architecture modules (surprisal EMA,
  belief state, neuromodulation) are individually unablated. Only the lessons block is tested.
- "Surprisal EMA is a positive contribution" — CHUMP_RESEARCH_BRIEF.md marked this "Confirmed"
  but the underlying evals (EVAL-011..015) show deltas ≈ 0 on qwen2.5:7b and a second-LLM
  rescore of −0.10 to −0.30. This claim must not be repeated until EVAL-043 (ablation) ships.
- "Neuromodulation improves task performance" — EVAL-029 shows net-negative cross-architecture
  signal (−0.10 to −0.16 mean delta). The fix (EVAL-030 task-class-aware gating) is shipped but
  not yet re-validated.
- "2000+ A/B trials validate Chump's cognitive architecture" — the trials validate the lessons
  block on haiku-4-5 on two fixture types. The broader architecture claim requires EVAL-043.

---

## Validated Findings (cite freely)

| Finding | Evidence | Confidence |
|---|---|---|
| Lessons block helps haiku-4-5 on reflection fixture | EVAL-025, n=100, cross-family judge | High |
| Lessons block backfires on sonnet-4-5 (+0.33 hallucination rate) | EVAL-027c, n=100 | High |
| Neuromod harm is cross-architecture, two distinct mechanisms | EVAL-029 drilldown | Medium (n=50, single judge) |
| Task-class-aware gating (EVAL-030) fixes neuromod harm on targeted task classes | EVAL-030 | Medium (not yet cross-validated) |
| LLM judge bias: Anthropic judges reward hallucinated tool calls | EVAL-010 human label subset | Medium (n=12 tasks) |

---

## Prohibited Claims

Do not write these in docs, PR descriptions, commit messages, or external communications
without first shipping the gap that would support them:

| Prohibited until | Supporting gap |
|---|---|
| "Surprisal EMA is a validated contribution" | EVAL-043 (ablation) |
| "Belief state improves agent performance" | EVAL-035 + EVAL-043 |
| "Chump's cognitive architecture is validated" | EVAL-043 full ablation suite |
| "All prior deltas are reliable" | EVAL-042 (cross-family judge re-run) + EVAL-041 (human grading) |
| "Neuromodulation is a net positive" | EVAL-030-VALIDATE cross-architecture + EVAL-043 |
| "Chump is publication-ready" | See Publication Readiness section below |

---

## Required Methodology Standards

Any new eval gap filed must specify:

1. **Sample size:** Minimum n=50 per cell for directional signal; n=100 for ship-or-cut decisions.
2. **Judge composition:** At least one non-Anthropic judge in the panel (Llama-3.3-70B via Together
   is $0 on the free tier). Anthropic-only judging is insufficient for publication.
3. **Human ground truth:** For any fixture where hallucination is the measured outcome, validate
   the detection regex against ≥20 human-labeled examples before citing results.
4. **Mechanism analysis:** If a delta is > ±0.05, document a hypothesis for *why* it appears.
   Unexplained deltas may be judge artifacts. Reference EVAL-029 as the model for mechanism
   drilldown.
5. **A/A baseline:** Every eval series must include at least one A/A run (same cell vs same cell)
   to measure judge variance. A/A delta should be within ±0.03 before results are cited.
6. **Reproduction:** The exact harness call (with CHUMP_EXPERIMENT_CHECKPOINT from
   INFRA-EXPERIMENT-CHECKPOINT) must be logged in the eval doc. Results without a reproducible
   call are preliminary only.

> **⚠️ python3 foot-gun (discovered 2026-04-20):** On this machine `python3` resolves to 3.14,
> which has no `anthropic` module. Using it silently produces `scorer=exit_code_fallback` in every
> JSONL row — no real LLM-judge scores, no error message. Always use `python3.12` and verify:
> `python3.12 -c 'import anthropic; print("ok")'`. All sweep launch commands must use `python3.12` explicitly.

---

## What Needs to Be Fixed (active gaps)

These gaps exist specifically to correct the methodology:

| Gap | What it fixes | Priority |
|---|---|---|
| EVAL-041 | Human grading of all task-fixture pairs (complete EVAL-010) | P1 |
| EVAL-042 | Cross-family judge (non-Anthropic) re-run of all main findings | P1 |
| EVAL-043 | Independent ablation: belief_state, surprisal, neuromod each in isolation | P1 |
| EVAL-044 | Multi-turn evaluation fixture (current evals are all single-shot) | P2 |
| RESEARCH-002 | Update all docs (PROJECT_BRIEF, RESEARCH_BRIEF, FACULTY_MAP) to match accurate thesis | P1 |

---

## Documentation That Is Currently Inaccurate

These docs contain claims that conflict with this directive. Do not propagate their framing.
File RESEARCH-002 work by updating these files:

- **docs/CHUMP_RESEARCH_BRIEF.md** — "Surprisal EMA: Confirmed" must be changed to "Unablated / preliminary"
- **docs/CHUMP_PROJECT_BRIEF.md** — research section claims "cognitive architecture validated" across multiple faculties; must be narrowed to the lessons-block finding
- **docs/CHUMP_FACULTY_MAP.md** — Metacognition row says "net-negative signal" but is still listed as active research direction without noting that it may need to be removed if EVAL-043 confirms net harm
- **docs/CONSCIOUSNESS_AB_RESULTS.md** — Headline deltas cited without noting judge-bias caveat; add standing caveat at top of file

---

## Path to Publication Readiness

To publish findings (blog post, arXiv, or conference):

**Minimum viable (HackerNews / practitioner blog):**
- [ ] EVAL-041: Human grading baseline (40 hrs)
- [ ] EVAL-042: Non-Anthropic judge re-run ($5 cloud)
- [ ] Reframe thesis to the tier-dependent injection finding (RESEARCH-002)

**Full publication (arXiv / workshop paper):**
- [ ] All of the above
- [ ] EVAL-043: Full ablation suite ($15 cloud)
- [ ] EVAL-044: Multi-turn fixture ($10 cloud)
- [ ] n≥100 on all cited results
- [ ] Mechanism analysis for every delta > ±0.05

Total incremental cost: ~$30–50 cloud, ~60 hrs human time.

---

## For Agent Sessions

Before starting any gap that:
- touches `src/reflection_db.rs`, `src/briefing.rs`, or `src/agent_loop/`
- adds or modifies eval fixtures or harness config
- writes research claims in docs or PR descriptions

...check: does your planned change conflict with the Prohibited Claims table above?
If yes, either file the supporting gap first or scope your claim to what the evidence supports.

When writing PR descriptions or commit messages: use "preliminary" for any delta from n<100 runs
with Anthropic-only judges. Use "validated" only for findings that meet the standards above.
