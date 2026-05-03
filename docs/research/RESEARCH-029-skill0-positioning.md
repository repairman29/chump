---
doc_tag: position-statement
owner_gap: RESEARCH-029
last_audited: 2026-05-03
---

# RESEARCH-029 — SKILL0 vs Chump Lesson Injection: Position Statement

> **Status:** Position statement, not an experiment. Reaches a strategic
> decision per gap acceptance criteria; does not run new trials.
> Pre-existing evidence base: `docs/process/RESEARCH_INTEGRITY.md`
> (binding) plus EVAL-076 / EVAL-095 / EVAL-096 (in-flight).

## What SKILL0 claims

Per the gap description and the cited paper
([huggingface.co/papers/2604.02268](https://huggingface.co/papers/2604.02268),
April 2026, "In-Context Agentic Reinforcement Learning for Skill Internalization"):

- **Mechanism:** training-time curriculum that teaches an agent skills via
  in-context examples, then **progressively withdraws** the skill context
  during deployment.
- **Result:** agents retain skill performance with **<0.5K tokens per step**
  at inference time — i.e. the skills end up internalized in the weights,
  not re-injected at every call.
- **Implicit thesis:** the "right" place for agent skills is in model
  parameters (after a curriculum), not in the runtime prompt.

The strategic challenge to Chump: if Chump's haiku-tier improvement is
fundamentally an **internalization effect that happens to be triggered
each session via prompt injection**, then SKILL0 reaches the same
destination via a cheaper-at-inference path — and Chump's per-session
prompt overhead is a transitional bridge, not a moat.

## What Chump's evidence actually shows

Per `docs/process/RESEARCH_INTEGRITY.md` (binding, supersedes all other
framing):

> Instruction injection at inference time has systematically different
> effects by model tier and task class. Prescriptive directives improve
> task performance on small models (haiku-4-5) on specific task types
> (reflection, perception), but actively harm performance on frontier
> models (sonnet-4-5+) — confirmed at n=100 with cross-family validation.
> The harm mechanisms are diagnosable: conditional-chain dilution and
> trivial-token contamination.

Chump does NOT have evidence for any of the following (per the same
binding doc): "cognitive architecture improves agent performance,"
"surprisal EMA is positive," "neuromodulation improves task performance,"
"2000+ A/B trials validate the cognitive architecture." Only the
**lessons block on haiku, on two fixture types** has cross-family
n=100 confirmation.

This narrows the field of comparison: SKILL0 vs **Chump's lessons-block
effect on haiku-tier**, specifically.

## The mechanistic comparison

| | SKILL0 | Chump lessons-block |
|---|---|---|
| **Where the skill lives** | Model weights (after training) | Prompt prefix (every call) |
| **Where it's installed** | Training-time curriculum | Runtime injection |
| **Inference-time cost** | <0.5K tokens/step | Full lessons block on every call (~500–5000 tokens depending on top-N) |
| **Tier-dependence** | Single trained model | Helps small (haiku), harms large (sonnet+) |
| **Adaptation latency** | Re-train to update | Edit a JSON; effect on next call |
| **Addressable model surface** | Models you can fine-tune | Any prompt-accepting model |

These are mechanistically distinct. SKILL0 changes the model; Chump
changes the prompt. But **the overlap question is whether the *effect*
is the same** — does Chump's prompt-injected lessons block produce
behavior that SKILL0-trained weights would also produce?

We don't know directly. Plausibility: probably yes for behaviors that
are pattern-completion-shaped (reflection, perception heuristics), and
probably no for behaviors that depend on multi-turn state or tool
interaction sequences. SKILL0's paper claims hold under their training
regime; Chump's measurements are on commodity foundation models with no
fine-tuning.

## The "is this a bridge?" question

**Yes, partly. Chump's lessons-block effect on haiku is most likely a
bridge.** The most parsimonious explanation for why a prescriptive
directive helps a small model but harms a large one is:

- **Small model:** lacks the relevant skill internalized, benefits from
  having the directive in-context as a recipe.
- **Large model:** already has the skill internalized, is harmed by the
  directive's conditional-chain dilution / trivial-token contamination
  (from the same binding doc).

If that's right, SKILL0-style training of haiku (or whatever Anthropic's
next-gen small model is) on a curriculum that includes Chump's lessons
content would **collapse Chump's measured haiku-tier delta to zero** —
because the small model would no longer need the in-context recipe.

**This is the threat.** Not that SKILL0 invalidates Chump's findings —
they remain true on current commodity models — but that the *commercial
window* for runtime lesson-injection on small models closes as
small-model training catches up to small-model deployment patterns.

## What Chump's lesson injection IS, when SKILL0 lands

Even granting the bridge framing, two adaptation surfaces remain that
SKILL0 by construction does not cover:

1. **Per-deployment / per-codebase customization.** SKILL0 trains a
   model once on a generic curriculum. Chump's `chump_improvement_targets`
   table grows from this *specific* dogfood corpus's failures —
   "subagent self-ship rate is 25-33%, here are the patterns that fix
   it" is not in any pretraining corpus. Even after SKILL0 lands,
   per-codebase / per-team adaptation needs a runtime injection layer
   OR another curriculum round (which has weeks of latency).

2. **Cheap experimentation on what to inject.** Chump's lessons-block
   evolves daily; SKILL0 curricula re-train monthly at best. If the
   research question is "which directives actually help?" the iteration
   loop has to be runtime, then findings can graduate to a curriculum.
   This positions Chump as the **A/B harness that produces the
   curriculum content** for downstream training — a different value
   proposition than "best-in-class agent runtime."

## Strategic verdict

**Chump's lesson injection is mechanistically distinct from SKILL0
internalization but produces overlapping effects on the haiku-tier
benchmark we have measured. This makes Chump a transitional layer for
that specific benefit:**

- **Now (2026):** runtime lesson injection delivers measurable haiku-tier
  improvement on commodity models that have not been SKILL0-curriculum-trained.
- **As SKILL0-style training propagates into commodity small models
  (12-24mo plausible):** the haiku-tier benefit of lesson injection
  shrinks toward zero. The frontier-tier *harm* (already documented)
  does not shrink — runtime injection remains a bad idea on large
  models regardless.
- **Durable Chump value:** per-deployment adaptation (your codebase's
  specific failure patterns) and the A/B harness that discovers what
  belongs in a future training curriculum.

## Implications for PRODUCT-009

`PRODUCT-009` is the publication-framing gap. The current framing
("cognitive architecture improves agent performance") is already
explicitly disallowed by `RESEARCH_INTEGRITY.md`. This position
statement adds a second constraint:

**Do not frame Chump as "the cognitive architecture for agent skill
acquisition."** That positioning competes directly with SKILL0 on
SKILL0's terms (training-time skill installation), and Chump loses
that comparison by construction (no fine-tuning loop, no curriculum
infrastructure, no inference-cost-per-step number to publish).

**Acceptable framing alternatives:**

1. **"Per-deployment adaptation harness for commodity models"** —
   honest about runtime-injection mechanism + per-codebase scope.
   Doesn't compete with SKILL0; complements it.

2. **"Empirical pipeline for discovering which agent directives
   improve task performance, by tier and task class"** — Chump's A/B
   harness as the contribution. The lessons content is the byproduct;
   the methodology is the artifact.

3. **"Runtime workflow tooling that survives whatever happens to the
   underlying models"** — the dispatcher / merge-queue / pipeline
   self-healing layer (where most of the recent shipping has gone) is
   orthogonal to the SKILL0 question entirely.

**Disallowed framings (per binding integrity doc + this position):**

- "Cognitive architecture for agents" (banned by integrity doc).
- "Skill-injection competitor to SKILL0" (loses comparison by
  construction).
- "2000+ A/B trials validate Chump's approach" (banned by integrity doc).
- "Runtime lessons block as the long-term answer" (this position
  states it's transitional for the commodity-small-model use case).

## Decision: no experiment needed at this time

The gap acceptance offered two paths: (a) experiment ruling out simple
internalization, or (b) strategic decision that lesson injection is a
transition mechanism. **This statement chooses (b).**

Rationale: a clean experiment ruling out internalization would require
training a haiku-equivalent model on a SKILL0-style curriculum
including Chump's lessons content, then measuring whether the trained
model still benefits from runtime injection. We do not have a fine-tuning
pipeline; we do not have access to weights to train. Even commissioning
this would cost $10K+ in compute and several weeks. The cheaper
strategic move is: accept the transition framing, adjust PRODUCT-009
positioning accordingly, and watch SKILL0-derivative work on commodity
small models for the next 12-24 months. If a SKILL0-style commodity
small model lands AND still benefits from Chump-style runtime injection,
that's the positive surprise that re-opens (a). Until then, framing
discipline per the alternatives above is the lower-risk position.

## Followups

- **PRODUCT-009 needs an amendment** to flag the disallowed framings
  added here. File as a small follow-up gap if not already in scope.
- **Track SKILL0 derivative literature** quarterly — same cadence as
  FRONTIER-006 (AMI/JEPA tracking). Add to the next strategic memo
  cycle.
- **Re-evaluate this position** if (a) a SKILL0-trained commodity small
  model is released and we can measure runtime-injection benefit on
  it, OR (b) the haiku-tier delta shrinks substantially in our own
  re-runs (EVAL-096 in-flight, cross-judge n=100 should give us a
  signal within weeks).

Net-new-docs: +1
