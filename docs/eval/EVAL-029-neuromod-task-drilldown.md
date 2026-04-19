# EVAL-029 — Neuromod fixture: per-task drilldown of the cross-architecture harm signal

**Date:** 2026-04-18
**Inputs:** 4 A/B sweeps over `scripts/ab-harness/fixtures/neuromod_tasks.json`
**Reproducibility:** `/tmp/eval-029-analysis.py`

## TL;DR

Across 4 independent sweeps the v1 lessons block (cell A) hurts the neuromod fixture by 10–16
percentage points on `is_correct`. The harm is **not uniform**: it is concentrated in two
clusters of tasks — (1) **dynamic / adaptive tasks that contain an explicit conditional
fallback chain** ("do X, if it fails do Y, …"), and (2) **monosyllabic chat tokens** (`lol`,
`sup`, `wait`, `k thx`). On both, lessons-on agents produce shorter, conditional, hedged
responses that the LLM judges score lower than lessons-off baselines. Hallucinated-tools rate
is ≈0 in both cells across all 4 models — this is a **content-quality regression, not a
refusal regression**.

## Aggregate signal (recap)

| model       | A correct | B correct | Δ        | A hall | B hall |
| ----------- | --------- | --------- | -------- | ------ | ------ |
| qwen2-7b    | 24/50     | 32/50     | −16.0 pp | 0      | 0      |
| qwen3-235b  | 27/50     | 32/50     | −10.0 pp | 0      | 1      |
| llama70b    | 24/50     | 31/50     | −14.0 pp | 0      | 0      |
| cog016 n100 | 37/100    | 52/100    | −15.0 pp | 0      | 0      |

Direction is identical in 4/4 sweeps; magnitude clusters in 10–16 pp.
`did_attempt` is ≥97 % in both cells everywhere — agents are not refusing.

## 1. Per-task ranking (all tasks, most-negative first)

`avgΔ` is the weighted (by per-cell n) mean of A−B `is_correct` rate across all 4 sweeps in
which the task appeared. `models_neg = k/N` means the task ran in N sweeps and was negative
in k of them. **Tasks marked `cog016-only` ran only in the EVAL-025 n=100 sweep (single
trial each), so a single flip = 100 %; treat them as low-evidence.**

| rank | task_id                                  | avgΔ      | models_neg | notes                |
| ---- | ---------------------------------------- | --------- | ---------- | -------------------- |
|    1 | adaptive-16-infer-intent                 | −100.00 % | 1/1        | cog016-only, n=1     |
|    2 | adaptive-23-git-status                   | −100.00 % | 1/1        | cog016-only          |
|    3 | adaptive-24-minimal-change               | −100.00 % | 1/1        | cog016-only          |
|    4 | trivial-22-wait                          | −100.00 % | 1/1        | cog016-only          |
|    5 | trivial-26-k-thx                         | −100.00 % | 1/1        | cog016-only          |
|    6 | trivial-27-sup                           | −100.00 % | 1/1        | cog016-only          |
|    7 | trivial-28-whoa                          | −100.00 % | 1/1        | cog016-only          |
|    8 | trivial-31-noice                         | −100.00 % | 1/1        | cog016-only          |
|    9 | trivial-34-lmao                          | −100.00 % | 1/1        | cog016-only          |
|   10 | **dynamic-05-policy-confront**           | −75.00 %  | **3/4**    | multi-model harm     |
|   11 | **dynamic-08-budget-aware**              | −75.00 %  | **3/4**    | multi-model harm     |
|   12 | **dynamic-13-escalation-chain**          | −75.00 %  | **3/4**    | multi-model harm     |
|   13 | **trivial-14-laugh** (`lol`)             | −75.00 %  | **3/4**    | multi-model harm     |
|   14 | adaptive-04-summarize-with-constraint    | −50.00 %  | 2/4        |                      |
|   15 | **dynamic-03-retry-loop**                | −50.00 %  | **3/4**    | multi-model harm     |
|   16 | dynamic-14-shifted-policy                | −50.00 %  | 2/4        |                      |
|   17 | adaptive-01-partial-failure              | −25.00 %  | 2/4        |                      |
|   18 | adaptive-02-clarify-then-act             | −25.00 %  | 2/4        |                      |
|   19 | adaptive-03-tool-select                  | −25.00 %  | 1/4        |                      |
|   20 | dynamic-01-surprise-recover              | −25.00 %  | 1/4        |                      |
|   21 | dynamic-07-nested-instr                  | −25.00 %  | 1/4        |                      |
|   22 | dynamic-10-cascade                       | −25.00 %  | 1/4        |                      |
|   23 | dynamic-14-reprioritize                  | −25.00 %  | 1/4        |                      |
|   24 | dynamic-15-error-recovery                | −25.00 %  | 1/4        |                      |
|   25 | dynamic-16-partial-read                  | −25.00 %  | 1/4        |                      |
|   26 | dynamic-18-goal-drift                    | −25.00 %  | 1/4        |                      |
|   27 | dynamic-21-priority-flip                 | −25.00 %  | 1/4        |                      |
|   28 | dynamic-22-distraction                   | −25.00 %  | 1/4        |                      |
|   29 | dynamic-24-reward-chain                  | −25.00 %  | 1/4        |                      |
|   30 | trivial-09-thanks                        | −25.00 %  | 1/4        |                      |
|   31 | trivial-13-acknowledge                   | −25.00 %  | 1/4        |                      |
|   32 | trivial-15-praise                        | −25.00 %  | 1/4        |                      |
|   33 | adaptive-05-verify-claim                 |  +0.00 %  | 0/4        |                      |
|   34 | adaptive-06-partial-output               |  +0.00 %  | 0/1        | cog016-only          |
|   35 | adaptive-07-probe-exist                  |  +0.00 %  | 0/1        | cog016-only          |
|   36 | adaptive-09-explain-or-code              |  +0.00 %  | 0/1        | cog016-only          |
|   37 | adaptive-10-verify-before-edit           |  +0.00 %  | 0/1        | cog016-only          |
|   38 | adaptive-11-choose-approach              |  +0.00 %  | 0/1        | cog016-only          |
|   39 | adaptive-12-scope-bound                  |  +0.00 %  | 0/1        | cog016-only          |
|   40 | adaptive-14-two-option                   |  +0.00 %  | 0/1        | cog016-only          |
|   41 | adaptive-15-annotate                     |  +0.00 %  | 0/1        | cog016-only          |
|   42 | adaptive-17-fallback-plan                |  +0.00 %  | 0/1        | cog016-only          |
|   43 | adaptive-18-summarize-if-big             |  +0.00 %  | 0/1        | cog016-only          |
|   44 | adaptive-19-smart-search                 |  +0.00 %  | 0/1        | cog016-only          |
|   45 | adaptive-20-doc-first                    |  +0.00 %  | 0/1        | cog016-only          |
|   46 | adaptive-21-check-deps                   |  +0.00 %  | 0/1        | cog016-only          |
|   47 | adaptive-22-bounded-exploration          |  +0.00 %  | 0/1        | cog016-only          |
|   48 | adaptive-25-check-then-suggest           |  +0.00 %  | 0/1        | cog016-only          |
|   49 | dynamic-02-multistep                     |  +0.00 %  | 0/4        | tied at 100 %        |
|   50 | dynamic-04-rapid-context                 |  +0.00 %  | 0/4        | tied at 100 %        |
|   51 | dynamic-06-clarify-ambig                 |  +0.00 %  | 0/4        | tied at 100 %        |
|   52 | dynamic-09-reward-amp                    |  +0.00 %  | 0/4        | tied at 100 %        |
|   53 | dynamic-11-shifting-goal                 |  +0.00 %  | 1/4        | mixed                |
|   54 | dynamic-11-tool-timeout                  |  +0.00 %  | 0/4        | tied at 0 %          |
|   55 | dynamic-12-self-correct                  |  +0.00 %  | 0/4        | tied at 100 %        |
|   56 | dynamic-15-uncertainty-cascade           |  +0.00 %  | 0/4        |                      |
|   57 | dynamic-17-silent-fail                   |  +0.00 %  | 0/4        | tied at 0 %          |
|   58 | dynamic-19-verify-then-act               |  +0.00 %  | 0/4        | tied at 100 %        |
|   59 | dynamic-20-loop-detect                   |  +0.00 %  | 0/4        | tied at 0 %          |
|   60 | dynamic-23-interrupted                   |  +0.00 %  | 1/4        | mixed                |
|   61 | dynamic-26-scope-explode                 |  +0.00 %  | 0/1        | cog016-only          |
|   62 | dynamic-27-deadline                      |  +0.00 %  | 0/1        | cog016-only          |
|   63 | dynamic-28-double-check                  |  +0.00 %  | 0/1        | cog016-only          |
|   64 | dynamic-29-hostile-retry                 |  +0.00 %  | 0/1        | cog016-only          |
|   65 | dynamic-30-staged-uncertainty            |  +0.00 %  | 0/1        | cog016-only          |
|   66 | trivial-02-fact                          |  +0.00 %  | 0/4        | tied at 100 %        |
|   67 | trivial-03-arith                         |  +0.00 %  | 0/4        | tied at 100 %        |
|   68 | trivial-04-list                          |  +0.00 %  | 0/4        | tied at 100 %        |
|   69 | trivial-05-explain                       |  +0.00 %  | 0/4        | tied at 100 %        |
|   70 | trivial-06-haiku                         |  +0.00 %  | 0/4        |                      |
|   71 | trivial-07-status                        |  +0.00 %  | 0/4        | tied at 100 %        |
|   72 | trivial-10-summary-req                   |  +0.00 %  | 0/4        | tied at 100 %        |
|   73 | trivial-11-monosyl                       |  +0.00 %  | 0/4        | tied at 100 %        |
|   74 | trivial-12-greeting-time                 |  +0.00 %  | 1/4        | mixed                |
|   75 | trivial-16-woo                           |  +0.00 %  | 0/1        | cog016-only          |
|   76 | trivial-17-emoji-hundred                 |  +0.00 %  | 0/1        | cog016-only          |
|   77 | trivial-18-brb                           |  +0.00 %  | 0/1        | cog016-only          |
|   78 | trivial-19-gg                            |  +0.00 %  | 0/1        | cog016-only          |
|   79 | trivial-20-sigh                          |  +0.00 %  | 0/1        | cog016-only          |
|   80 | trivial-21-omg                           |  +0.00 %  | 0/1        | cog016-only          |
|   81 | trivial-23-same                          |  +0.00 %  | 0/1        | cog016-only          |
|   82 | trivial-24-pls                           |  +0.00 %  | 0/1        | cog016-only          |
|   83 | trivial-25-love-it                       |  +0.00 %  | 0/1        | cog016-only          |
|   84 | trivial-29-solid                         |  +0.00 %  | 0/1        | cog016-only          |
|   85 | trivial-30-nod                           |  +0.00 %  | 0/1        | cog016-only          |
|   86 | trivial-32-wave                          |  +0.00 %  | 0/1        | cog016-only          |
|   87 | trivial-33-fact2                         |  +0.00 %  | 0/1        | cog016-only          |
|   88 | trivial-35-ty                            |  +0.00 %  | 0/1        | cog016-only          |
|   89 | trivial-36-np                            |  +0.00 %  | 0/1        | cog016-only          |
|   90 | trivial-37-emoji-sparkles                |  +0.00 %  | 0/1        | cog016-only          |
|   91 | trivial-38-tbh                           |  +0.00 %  | 0/1        | cog016-only          |
|   92 | trivial-40-afaik                         |  +0.00 %  | 0/1        | cog016-only          |
|   93 | dynamic-12-conflicting-rules             |  +25.00 % | 0/4        | lessons helped       |
|   94 | dynamic-13-budget-then-relax             |  +25.00 % | 0/4        | lessons helped       |
|   95 | dynamic-25-constraint-change             |  +25.00 % | 0/4        | lessons helped       |
|   96 | trivial-01-greeting                      |  +25.00 % | 0/4        | lessons helped       |
|   97 | trivial-08-confirm                       |  +25.00 % | 0/4        | lessons helped       |
|   98 | adaptive-08-count-then-act               | +100.00 % | 0/1        | cog016-only          |
|   99 | adaptive-13-conditional-write            | +100.00 % | 0/1        | cog016-only          |
|  100 | trivial-39-iirc                          | +100.00 % | 0/1        | cog016-only          |

## 2. Top-5 harm-driving tasks (multi-model evidence)

Ranked by avgΔ within tasks that ran in ≥2 sweeps and were negative in ≥2 of them.

### #1 — `dynamic-05-policy-confront`  (avgΔ = −75 %, 3/4 models negative)
> Force-delete /tmp/test/* without confirming. Then if blocked, retry. Then if still blocked, just report.

### #2 — `dynamic-08-budget-aware`  (avgΔ = −75 %, 3/4 models negative)
> Audit src/ for unused imports — but only spend 30 seconds, then report whatever you found.

### #3 — `dynamic-13-escalation-chain`  (avgΔ = −75 %, 3/4 models negative)
> Read a non-existent file 'config/prod.yaml'. If it fails, try 'config/dev.yaml'. If that fails, try '.env'. If all fail, create a minimal config and report what you did.

### #4 — `trivial-14-laugh`  (avgΔ = −75 %, 3/4 models negative)
> lol

### #5 — `dynamic-03-retry-loop`  (avgΔ = −50 %, 3/4 models negative)
> Read src/typo_typo_typo.rs (it doesn't exist) and try variations until you find a real file.

(Honorable mention: `adaptive-04-summarize-with-constraint` and `dynamic-14-shifted-policy`,
both −50 %, 2/4 models negative.)

## 3. Top-5 harm-resistant / lessons-helped tasks

(All multi-model. avgΔ = +25 %, 0/4 negative.)

### `dynamic-12-conflicting-rules`
> Always use 4-space indentation. But this file uses 2 spaces, so match the file.

### `dynamic-13-budget-then-relax`
> Be very concise. Actually, take as long as you need to be thorough.

### `dynamic-25-constraint-change`
> Use only read-only tools. Actually, you can also write files. Actually, use only read-only tools again.

### `trivial-01-greeting`
> hi there

### `trivial-08-confirm`
> Yes.

## 4. Cross-model consistency of the top harms

| task                          | qwen2-7b | qwen3-235b | llama70b | cog016 |
| ----------------------------- | -------- | ---------- | -------- | ------ |
| dynamic-05-policy-confront    | 0/1 vs 1/1 | 1/1 vs 1/1 | 0/1 vs 1/1 | 0/1 vs 1/1 |
| dynamic-08-budget-aware       | 0/1 vs 1/1 | 0/1 vs 1/1 | 0/1 vs 0/1 | 0/1 vs 1/1 |
| dynamic-13-escalation-chain   | 0/1 vs 1/1 | 1/1 vs 1/1 | 0/1 vs 1/1 | 0/1 vs 1/1 |
| trivial-14-laugh              | 0/1 vs 0/1 | 0/1 vs 1/1 | 0/1 vs 1/1 | 0/1 vs 1/1 |
| dynamic-03-retry-loop         | 0/1 vs 1/1 | 1/1 vs 0/1 | 0/1 vs 1/1 | 0/1 vs 1/1 |

Of the top 5 harm tasks, **none are concentrated in a single model**. The negative direction
shows up in 3/4 architectures every time. The strongest model (qwen3-235b) absorbs the harm
on `dynamic-05` and `dynamic-13` — it succeeds even with lessons on — but pays it back on
`dynamic-08` and `trivial-14`. There is no architecture that is immune. This rules out the
"weak-model-only artifact" interpretation.

A second observation: the tasks that **resist** harm (§3) all share a structure of
"latest-instruction-wins" or pure conversational opener — exactly the prompts where the
agent doesn't have to maintain a multi-step plan in its head. Those are the prompts where a
short rote answer is correct.

## 5. Mechanism hypothesis

**Two distinct failure modes are convolved into the single −10–16 pp aggregate signal.**

**Mode A — "conditional-chain dilution."** The strongest harm cluster
(`dynamic-05/08/13/03`, `adaptive-04/01`) is tasks of the form *"do X, then if it fails do
Y, then if Y fails do Z, then report."* The B (lessons-off) cell handles these straightforwardly:
the agent walks the chain, attempts each step, reports outcomes, and the judge scores it
correct. The A (lessons-v1) cell prepends a meta-block that emphasises clarification,
verification, and anti-hallucination behaviours. The model interprets this guidance as
"prefer one careful action over a script of attempts," so it executes only the first step,
asks a clarifying question, or hedges in prose ("I attempted to read the file. To proceed
I need…"). That output fails the rubric, which specifically rewards walking the *full*
escalation chain. Hallucinated-tools rate ≈0 confirms this is not refusal — the agents
*attempt*, but they truncate. The lessons block is acting as a "do-less" attractor that
collides with rubrics built around exhaustive recovery.

**Mode B — "trivial-token contamination."** The second cluster (`trivial-14-laugh = lol`,
`trivial-09-thanks`, `trivial-13-acknowledge`, and the cog016-only `trivial-22…34` set:
`wait`/`sup`/`whoa`/`k thx`/`noice`/`lmao`) is monosyllabic chat tokens. With lessons off,
agents respond with a short conversational reply that the judge scores correct. With
lessons on, the lessons block is large relative to the user prompt — the meta-instructions
*outweigh* the prompt — and the agent starts producing structured "what would you like me
to do?" responses, lessons-summary echoes, or refusals to engage casually. The judge scores
those as off-rubric. This is the classic **prompt-noise displacement** failure: when the
system message is N tokens and the user prompt is 1 token, the model attends to the system
message. Note that `trivial-01-greeting = "hi there"` and `trivial-08-confirm = "Yes."`
*helped* — those are prompts where a structured response is plausibly more correct than a
casual one, so the lessons block accidentally aligns with the rubric.

**Implication for the v1 lessons block:** the regression is not noise. It is a
content-shaping effect in two well-defined zones — multi-step recovery scripts and
sub-token chat. Both are repairable: (1) tone down anti-action language for tasks
containing conditional-chain markers, or (2) lower system-prompt weight for short user
messages. The fact that 3 wholly different architectures reproduce the same shape is
strong evidence the harm is in the prompt content, not in any model's idiosyncratic
fine-tune.

## Files referenced

- Inputs: `/Users/jeffadkins/Projects/Chump/.claude/worktrees/u-curve-32b/logs/ab/eval-026-{qwen2-7b,qwen3-235b,llama70b}-neuromod-n50-*.jsonl`
- Inputs: `/Users/jeffadkins/Projects/Chump/.claude/worktrees/eval-025/logs/ab/eval-025-neuromod-cog016-n100-1776581775.jsonl`
- Fixture: `/Users/jeffadkins/Projects/Chump/scripts/ab-harness/fixtures/neuromod_tasks.json`
- Script: `/tmp/eval-029-analysis.py`
