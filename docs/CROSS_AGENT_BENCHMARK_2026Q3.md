# Cross-Agent Benchmark 2026 Q3

> **Status: PENDING** — framework and methodology complete; result cells require a live harness run.
> See [Reproduction](#reproduction) for the exact commands.
>
> **Research integrity:** all result columns below are marked PENDING. Do not cite numeric results
> until a full run completes (n≥50 per cell per agent, non-Anthropic judge in panel).
> Methodology follows `docs/RESEARCH_INTEGRITY.md`.

---

## Executive Summary

Chump's `run-cloud-v2.py` + `scoring_v2` multi-axis A/B harness is differentiated infrastructure
in the local-agent ecosystem: it produces Wilson-confidence-interval-bounded, multi-axis
(correctness, attempt rate, hallucination rate) scores with A/A noise-floor calibration and
cross-family judge validation. No other open-source agent project currently publishes
methodologically comparable self-measurement.

By applying this harness to competing agents on the same fixtures Chump tests itself with,
Chump becomes **the measurement layer for the local-agent ecosystem** — not merely another
agent, but the system that tells the community how agents compare on specific task classes.

This document covers:
- The adapter framework that makes cross-agent runs possible ([`scripts/ab-harness/cross-agent-adapter.py`](../scripts/ab-harness/cross-agent-adapter.py))
- Methodology (fixtures, scoring dimensions, judge panel)
- Pending result tables (filled in from actual runs)
- Discussion of what results would imply
- Reproduction commands

---

## Agents Under Test

| Agent | CLI | Backend | Runner class | Status |
|---|---|---|---|---|
| **Chump** (haiku-4-5) | built-in API call | Anthropic `claude-haiku-4-5` | `ChumpRunner` | Reference |
| **Goose** (Block, haiku-4-5) | `goose run --text <prompt>` | Anthropic via goose config | `GooseRunner` | Pending install |
| **Aider** (Paul Gauthier) | `aider --message <prompt> --no-git` | Anthropic `claude-haiku-4-5` | `AiderRunner` | Pending install |
| **Claude Code** | `claude -p <prompt>` | Anthropic (default model) | `ClaudeCodeRunner` | Pending install |

All agents run the same `claude-haiku-4-5` backend where configurable, so model capability
differences do not confound the comparison. The comparison isolates **agent architecture
differences** (prompt framing, tool-call handling, system-prompt construction) from
**model capability differences**.

### Runner invocation details

**ChumpRunner** calls the Anthropic API directly, identical to `run-cloud-v2.py`, with the
lessons block injected as the system prompt (cell A) or no system prompt (cell B).

**GooseRunner** shells out to:
```bash
goose run --text "<system-as-context>\n\n<prompt>"
```
goose does not expose a `--system` flag; system context is prepended as a labelled block.
Install: `pip install goose-ai` or `brew install block-goose`, then `goose configure`.

**AiderRunner** shells out to:
```bash
aider --message "<prompt>" --no-git --no-auto-commits --yes-always [--model claude-haiku-4-5]
```
`--no-git` prevents Aider from modifying the repository. `--yes-always` suppresses
interactive prompts. Install: `pip install aider-chat`.

**ClaudeCodeRunner** shells out to:
```bash
claude -p "<prompt>"
```
`-p` activates non-interactive print mode. Install: `npm install -g @anthropic-ai/claude-code`.

When a CLI is not found, the runner returns `NOT_INSTALLED:<agent>`, which scores as
`did_attempt=False, hallucinated_tools=False, is_correct=False` — the correct signal for
"agent not available on this machine."

---

## Fixtures

Three fixtures from Chump's existing eval suite are used. Each fixture was validated in
prior EVAL-series runs; the same tasks are used here without modification.

| Fixture | File | Tasks | Description |
|---|---|---|---|
| **reflection** | `scripts/ab-harness/fixtures/reflection_tasks.json` | 100 | Tests error-recovery, clarification-seeking, policy adherence. Originally COG-011; expanded by EVAL-022. |
| **perception** | `scripts/ab-harness/fixtures/perception_tasks.json` | 100 | Tests structured-input extraction, risk recognition, ambiguity handling. Originally COG-005; expanded by EVAL-022. |
| **neuromod** | `scripts/ab-harness/fixtures/neuromod_tasks.json` | 100 | Tests multi-step planning, retry-loop handling, blocked-path escalation. Originally COG-006; expanded by EVAL-022. |

For this benchmark, n=50 tasks per fixture per agent is the target. Each task runs once
(no A/B cells at the agent level — the cross-agent design replaces the within-agent A/B).
Cells A and B are used for the optional Chump A/A noise-floor calibration only.

---

## Scoring Dimensions

Scoring uses `scripts/ab-harness/scoring_v2.py` unchanged. Three axes per trial:

| Axis | Meaning | How measured |
|---|---|---|
| **is_correct** | Response addresses the prompt correctly | LLM judge score ≥ 0.5 threshold |
| **did_attempt** | Made a real effort (not a bare refusal) | judge_score ≥ 0.3 OR long response with guidance |
| **hallucinated_tools** | Emitted fake `<function_calls>` / `<tool_call>` markup | Regex detection in `scoring_v2.HALLUCINATION_PATTERNS` |

Wilson 95% confidence intervals are computed on all rates. Deltas between agents are
reported with `cis_overlap` flags: `True` means the delta is within sampling noise and
**must not be cited as a finding**.

---

## Judge Panel

| Judge | Type | Role |
|---|---|---|
| `claude-sonnet-4-5` | Anthropic | Primary judge |
| `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` | Non-Anthropic (Together.ai free tier) | Cross-family validation |

Both judges are required per `docs/RESEARCH_INTEGRITY.md` §2 ("at least one non-Anthropic
judge in the panel"). Results scored by Anthropic-only judges are preliminary only.
The median verdict across judges is the canonical score.

---

## Results — Reflection Fixture

> **PENDING** — run with:
> ```
> python3 scripts/ab-harness/cross-agent-adapter.py \
>   --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
>   --agents chump goose aider claude-code \
>   --model claude-haiku-4-5 \
>   --judge "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
>   --limit 50 \
>   --tag cross-agent-reflection-2026Q3
> ```

| Agent | n | Correct rate | 95% CI | Attempt rate | Halluc rate | Mean judge |
|---|---|---|---|---|---|---|
| Chump (haiku-4-5) | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Goose | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Aider | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Claude Code | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |

---

## Results — Perception Fixture

> **PENDING** — run with:
> ```
> python3 scripts/ab-harness/cross-agent-adapter.py \
>   --fixture scripts/ab-harness/fixtures/perception_tasks.json \
>   --agents chump goose aider claude-code \
>   --model claude-haiku-4-5 \
>   --judge "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
>   --limit 50 \
>   --tag cross-agent-perception-2026Q3
> ```

| Agent | n | Correct rate | 95% CI | Attempt rate | Halluc rate | Mean judge |
|---|---|---|---|---|---|---|
| Chump (haiku-4-5) | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Goose | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Aider | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Claude Code | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |

---

## Results — Neuromod Fixture

> **PENDING** — run with:
> ```
> python3 scripts/ab-harness/cross-agent-adapter.py \
>   --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
>   --agents chump goose aider claude-code \
>   --model claude-haiku-4-5 \
>   --judge "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
>   --limit 50 \
>   --tag cross-agent-neuromod-2026Q3
> ```

| Agent | n | Correct rate | 95% CI | Attempt rate | Halluc rate | Mean judge |
|---|---|---|---|---|---|---|
| Chump (haiku-4-5) | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Goose | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Aider | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Claude Code | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |

---

## A/A Baseline Note

Before citing cross-agent deltas, run an A/A noise-floor calibration for Chump:

```bash
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
  --tag cross-agent-aa-chump-2026Q3 \
  --mode aa \
  --model claude-haiku-4-5 \
  --limit 50
```

An A/A delta outside ±0.03 on `is_correct` means judge variance is high enough to obscure
real cross-agent deltas. Fix: add more judges to the panel or increase n.

For cross-agent comparisons, there is no within-agent A/A; the comparable check is to run
the same agent twice and verify the results are stable.

---

## Discussion: What Results Would Mean

### If Chump scores higher than peers on reflection/perception

This would be evidence that Chump's lessons-block injection (COG-016 anti-hallucination
directive) has a real effect beyond what bare prompt-to-model calls achieve. It would
support the framing: "agent architecture — specifically what goes in the system prompt —
affects multi-axis performance, not just correctness."

This finding is consistent with, but does not prove, the broader claim that Chump's
cognitive architecture is beneficial. The isolated variable here is the system-prompt
construction, not surprisal EMA, belief state, or neuromodulation.

### If agents score similarly across fixtures

This would be an architecture-independent finding: for the task classes covered by these
fixtures, prompt framing alone does not differentiate agents running the same model. It
would still be a publishable result — it constrains which claims about agent architecture
are defensible.

### If Goose or Aider score *higher* on some fixtures

This would be a valuable discovery: it would identify fixture categories where Chump's
current architecture is sub-optimal. The mechanism drilldown (per `docs/RESEARCH_INTEGRITY.md`
§4) should examine whether the difference comes from system-prompt framing, tool-call
handling, or the task class itself.

### On hallucination rates specifically

Prior work (EVAL-023, EVAL-025, EVAL-027c) shows that hallucinated tool calls are highly
sensitive to the lessons block content and model tier. Cross-agent hallucination rate
comparison is one of the most diagnostically valuable outputs of this benchmark:

- If Chump's halluc rate > peers → the COG-016 directive is not sufficient.
- If Chump's halluc rate < peers → Chump's system-prompt construction is protective.
- If all agents hallucinate at similar rates → the fixture itself elicits hallucination
  regardless of agent framing; flag for EVAL-041 human-grading validation.

---

## Known Methodological Limitations

1. **Anthropic model confound.** All agents are configured to use `claude-haiku-4-5` where
   possible, but goose and Claude Code may use different model defaults. Document the
   actual model used per run in the summary JSON.

2. **System-prompt asymmetry.** Chump injects a lessons block as the system prompt. Goose
   and Aider have their own internal system prompts that we cannot control. This means the
   comparison is "Chump with lessons block vs agent-with-its-own-framing" — not a clean
   ablation of the lessons block alone. Use the ChumpRunner *without* lessons injection
   (cell B equivalent) as the fairer comparison baseline.

3. **Tool-call hallucination detection.** `scoring_v2.HALLUCINATION_PATTERNS` was
   calibrated against Chump's own output. Goose and Aider may use different markup
   conventions. Validate the regex against ≥20 human-labeled examples from each agent
   before citing hallucination rates (per `docs/RESEARCH_INTEGRITY.md` §3).

4. **Fixture scope.** These three fixtures test instruction-following and tool-call
   behavior on a single-turn, text-only basis. They do not measure multi-turn capability,
   file-edit quality, or agentic planning depth — areas where goose and Aider are
   specifically optimized. This benchmark is not a general capability comparison; it is a
   narrow test of the behaviors Chump's fixtures cover.

5. **Judge independence.** The non-Anthropic judge (`Llama-3.3-70B-Instruct-Turbo`) was
   not used to calibrate the rubrics. Inter-judge agreement < 0.80 (trial-level) is a flag
   that the rubric is ambiguous; resolve before citing results.

---

## Reproduction

### Prerequisites

```bash
# Anthropic API key
export ANTHROPIC_API_KEY=<your-key>

# Optional: non-Anthropic judge via Together.ai free tier
export TOGETHER_API_KEY=<your-key>

# Install agent CLIs (all optional — missing ones return NOT_INSTALLED)
pip install goose-ai           # or: brew install block-goose
pip install aider-chat
npm install -g @anthropic-ai/claude-code

# Configure goose (if installed)
goose configure
```

### Full benchmark run (all agents, all three fixtures)

```bash
cd /path/to/chump

for FIXTURE in reflection perception neuromod; do
  python3 scripts/ab-harness/cross-agent-adapter.py \
    --fixture "scripts/ab-harness/fixtures/${FIXTURE}_tasks.json" \
    --agents chump goose aider claude-code \
    --model claude-haiku-4-5 \
    --judge "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
    --limit 50 \
    --tag "cross-agent-${FIXTURE}-2026Q3"
done
```

Results are written to `logs/cross-agent/cross-agent-<fixture>-2026Q3-<ts>.jsonl`
and `.summary.json`.

### Single-agent spot-check

```bash
python3 scripts/ab-harness/cross-agent-adapter.py \
  --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
  --agents chump \
  --model claude-haiku-4-5 \
  --judge claude-sonnet-4-5 \
  --limit 10 \
  --tag spot-check
```

### Estimated cost

| Run | Trials | Estimated cost |
|---|---|---|
| 4 agents × 3 fixtures × n=50 | 600 agent + 600 judge calls | ~$15–25 (Anthropic) + $0 (Together free) |
| Single fixture, all 4 agents | 200 agent + 200 judge calls | ~$5–8 |
| Spot check (1 agent, 10 tasks) | 10 + 10 calls | ~$0.20 |

---

## Quarterly Cadence

This benchmark is designed to run quarterly. The tag convention is:

```
cross-agent-<fixture>-<YYYY>Q<N>
```

Results from each quarter are appended to this document as new dated sections below the
current section headers. The methodology section remains stable; only the results tables
update.

---

## See Also

- [`scripts/ab-harness/cross-agent-adapter.py`](../scripts/ab-harness/cross-agent-adapter.py) — runner implementations
- [`scripts/ab-harness/run-cloud-v2.py`](../scripts/ab-harness/run-cloud-v2.py) — base harness
- [`scripts/ab-harness/scoring_v2.py`](../scripts/ab-harness/scoring_v2.py) — multi-axis scoring
- [`docs/RESEARCH_INTEGRITY.md`](RESEARCH_INTEGRITY.md) — required methodology standards
- [`docs/CONSCIOUSNESS_AB_RESULTS.md`](CONSCIOUSNESS_AB_RESULTS.md) — existing Chump self-benchmark results
- [`docs/STRATEGY_VS_GOOSE.md`](STRATEGY_VS_GOOSE.md) — competitive positioning context
