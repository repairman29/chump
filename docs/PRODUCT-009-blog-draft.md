---
doc_tag: log
owner_gap: PRODUCT-009
last_audited: 2026-04-25
---

# Instruction Injection Is Non-Monotonic: What We Found After 2,600+ Agent A/B Trials

**Venue:** HackerNews / practitioner blog  
**Registry:** `PRODUCT-009` is **`status: open`** again as of 2026-04-22 — the gap was mistakenly closed before acceptance (no live URL in `docs/FINDINGS.md`, `closed_pr` was `TBD`). This draft still has to clear the acceptance rows.  
**Status:** Draft — pending external review before publication  
**Word count:** ~2,100  
**Reviewed against:** `docs/RESEARCH_INTEGRITY.md` (2026-04-20)  
**Intended audience:** ML engineers building production agent loops

---

We built an agent loop and instrumented it with a "lessons block" — a dynamically-assembled set of episode-distilled directives injected at the system role. The hypothesis was standard: give the agent its own distilled experience and it will make fewer mistakes.

On small models, it worked. On frontier models, it reliably made things worse. Then we spent six weeks figuring out exactly why, localized the harm to two specific task classes, built a fix, and along the way discovered that a single few-shot exemplar could move an OSS model from "chatty refusal" to "shipped a 737-line feature PR in production."

Here is what we found, with the caveats the data actually supports.

---

## What we built

Chump is an open-source multi-agent dispatcher: it takes a backlog of structured engineering tasks ("gaps"), assigns them to Claude Code subagents running in isolated git worktrees, and coordinates them through a lease-file system to prevent stomps. The "lessons block" is a component of its prompt assembler — it queries a reflection database of distilled episode summaries, ranks them by recency × frequency, and prepends the top-N lessons to every agent prompt at spawn time.

The practical theory: if the agent has made a mistake three times (committed without tests, left stale lease files, sent an overlong context), distill that into a directive and inject it at startup. Don't rely on fine-tuning; operate at inference time.

We ran A/B experiments across model tiers. What we got was not what we expected.

---

## Finding 1: The U-curve (model-tier-dependent effects)

Across five local models ranging from 1.5B to 14B parameters (Qwen2.5 1.5B/3B/7B/8B, Qwen3 14B), the effect of the lessons block on pass-rate is *non-monotonic*:

| Model | Δ pass-rate (lessons-on vs off) |
|-------|-------------------------------|
| Qwen2.5-1.5B | **+10 pp** |
| Qwen2.5-3B | **−5 pp** |
| Qwen2.5-7B | **−5 pp** |
| Qwen2.5-8B | 0 pp |
| Qwen3-14B | **+10 pp** |

Small models (1.5B) and large models (14B) benefit. Mid-size models (3B, 7B) are harmed. The 8B shows no detectable effect.

The shape is a U-curve: the intervention helps at the extremes and hurts in the middle.

**Why this matters for practitioners:** most published work on retrieval-augmented or exemplar-augmented prompting assumes monotonic benefit — more context implies more help. This finding empirically contradicts that assumption for a specific intervention class (system-role lessons block) evaluated across a controlled scan of model sizes. A fixed lessons block is the wrong shape for a heterogeneous agent fleet; the intervention must be model-tier-aware.

**Honest limits:** n=20 per cell per model is small, and confidence intervals are not computed for the per-model results in the source data. The task fixture is Chump-internal; generalization to external benchmarks (BFCL, HumanEval, MMLU) has not been measured. This is a single-team finding.

---

## Finding 2: Frontier models emit more fake tool calls with the lessons block

On Anthropic frontier models, the lessons block reliably increases the rate of hallucinated tool-call markup — responses that contain `<function_calls>` XML resembling a real tool invocation but with fabricated output. Mean effect: **+0.14 percentage points** (≈ +0.0014 absolute rate on a 0–1 indicator) across 2,600+ trial pairs.

That sounds small. The reason it matters: the A/A baseline on the same fixture, same model, same harness is **+0.013 pp**. The lessons-block effect is **10.7× the calibrated noise floor**.

The LLM judge — using `claude-haiku-4-5` — *rewards* this behavior. A response that narrates tool execution gets scored the same as a response that actually invokes a tool. This means the judge hides the harm: the lessons block simultaneously increases hallucination and makes the scoring system call it "success."

The v2 judge prompt (shipped in EVAL-046) explicitly distinguishes "mentions using a tool" from "actually invokes a tool via a tool-use round-trip" and reduces the bias measurably on the calibration set.

**Honest limits:** two architectures tested, both Anthropic family. The hallucinated-tools detector is a regex/grammar match; it will miss novel hallucination patterns it wasn't written for. The +0.14 pp absolute magnitude is small — the finding's significance is in the floor calibration.

---

## Finding 3: The harm is localized to two task classes

The aggregate harm signal isn't a diffuse "lessons blocks hurt everything." Per-task analysis across four model architectures showed that harm concentrates in two clusters:

**Cluster 1: Conditional-fallback chains.** Tasks with explicit multi-step conditional logic ("do X; if it fails, do Y; then Z"). The lessons block performs worst here — per-task harm of −50 to −75% on `is_correct` across 3 of 4 architectures tested. Hypothesis: the lessons block's prescriptive directives compete with the conditional structure in the task prompt, causing the model to short-circuit the fallback and commit to a single path.

**Cluster 2: Monosyllabic tokens.** Tasks where the correct response is a brief, literal acknowledgment (`lol`, `k thx`, `sup`). Per-task harm of −75% in 3 of 4 architectures. The lessons block appears to inflate response length and formality for tasks where brevity is the evaluation criterion.

Tasks outside these two clusters show approximately zero effect.

This localization is directly actionable. The fix — gate the lessons block on task class, suppress it on conditional-chain prompts and trivial tokens — is now the production default in Chump's prompt assembler (`CHUMP_LESSONS_TASK_AWARE=1`). On targeted task classes, the per-task harm disappeared in follow-up sweeps.

**Honest limits:** the aggregate harm signal (−10 to −16 pp across architectures) has not been reproduced under the fixed evaluation instrument introduced in EVAL-060. A re-run with the same modules and the fixed instrument saw near-zero aggregate delta (EVAL-063, n=50/cell). Whether the original aggregate signal was real or an artifact of the prior measurement methodology is an open question. The *per-task pattern* (the two clusters) is direction-consistent across 4/4 sweeps; the *aggregate magnitude* question is unresolved.

---

## The fix: task-class-aware gating

The lessons block now inspects the raw user prompt before injection. Two rules gate it off:

1. **Trivial-token detection:** if the trimmed prompt is under 30 characters, skip the lessons block entirely. The model doesn't need distilled episode wisdom to respond to "sup."

2. **Conditional-chain detection:** if the prompt matches a conditional-chain pattern (`if.*fail`, `try.*otherwise`, `do X.*if Y`, etc.), suppress the "ask one clarifying question" directive that the lessons block normally appends. The conditional logic is already in the task; the directive competes with it.

Neither rule requires an LLM call; both are string-pattern checks on the prompt at assembly time. The gates add approximately 0 latency.

We haven't published a controlled re-validation of the gating mechanism at n≥100 under cross-family judges. This is on the roadmap (EVAL-030-VALIDATE). The claim that it works is medium-confidence — the per-task harm disappeared in the sweeps that informed the fix, but that's the same data the fix was derived from.

---

## Bonus: one few-shot exemplar moves an OSS model from chat-default to shipping PRs

While the lessons-block work was running, we were trying to route tasks to Together-served instruct-tuned models (Qwen3-235B, Llama-3.3-70B, Qwen3-Coder-480B, DeepSeek-V3.1) to reduce cost. All four models defaulted to conversational behavior when given the dispatched-agent prompt:

- *"Would you like me to focus on a specific domain?"*
- *"I'm happy to help — what should I call you?"* (Qwen3-Coder with a directive overlay — *worse* than baseline)
- Multiple-choice menus (DeepSeek)
- Read-loop exhaustion (Qwen3-235B on iter=50)

Vanilla prompts, directive overlays, and preambles all failed to break the chat-default pattern across 7 trials.

What worked: **a single grounded few-shot exemplar trace** — drawn from a real prior shipped PR — showing the complete action sequence (`read_file → patch_file → chump-commit.sh → bot-merge.sh → terminal "PR #N"`), combined with an explicit "SHIP RULE" directive: *any commit must be immediately followed by `bot-merge.sh`.*

On trial V9 (Qwen3-Coder-480B, step-3a overlay), the model read the gap description, worked in an isolated worktree, made two commits, ran bot-merge, and shipped **PR #224 to main: 737 lines of code, two new MCP server crates, merged without human intervention**. Cost: approximately $0.20.

The technique is documented at the code level in `src/model_overlay.rs`. Anyone building an agent loop on Together / Ollama / mistral.rs can copy the exemplar pattern into their own system prompt.

**Honest limits:** this is an existence proof (n=1). The gap shipped was mostly-additive scaffolding work; harder gap classes (cross-file refactors, data-flow fixes) have not been tested. We're holding the replication trial pending resolution of methodology questions in the evaluation track. The fine-tuning path (a small OSS model trained on successful Chump traces, ~$50) is the long-term answer; the exemplar is a bandaid that buys time.

---

## What the LLM judge thinks vs what a human thinks

A separate finding from the methodology work (F5, preliminary): on three Chump fixtures, Cohen's κ between LLM-as-judge verdicts and human verdicts is: reflection 0.059, perception −0.250, neuromod 0.250. All below the substantial-agreement threshold of κ ≥ 0.70. The perception κ is negative — the judge and the human systematically disagree about what "correct" means.

Two bias patterns are categorical:
1. The LLM judge rewards hallucinated tool execution. A response that *describes* calling a tool gets the same score as one that actually calls it.
2. The LLM judge fails appropriate clarifying questions. A response that says "I need more context before I can answer this" gets score 0.0; human graders pass it.

Both patterns are consistent with a judge that has been RLHF'd to reward helpfulness and directness — the judge doesn't model the evaluation criterion, it models "what would a helpful response look like."

The v2 judge prompt fix addresses both explicitly and is now shipping in every harness call. The full re-score at n≥30 human labels is pending.

**Why this matters for your evals:** if you're using LLM-as-judge for agent evaluation without calibrating against human labels, your judge may be systematically rewarding failure modes you haven't instrumented. The calibration is cheap (12 human labels found both bias patterns); the measurement cost of skipping it is invisible until you look.

---

## How to replicate

All fixtures used in the studies above are in `scripts/ab-harness/fixtures/` in this repository. The harness commands are documented in the source eval docs (`docs/eval/EVAL-025-*`, `EVAL-027-*`, `EVAL-029-*`, `EVAL-042-*`, `EVAL-046-*`, `COG-031-*`).

Minimum cost to replicate F2 (halluc inflation, frontier models): ~$5 in Anthropic API + Together.ai free tier for the cross-family judge. The harness is `scripts/ab-harness/run-catattack-sweep.py` and `run-catattack-sweep-cloud.py`.

We explicitly invite replication. None of F1–F6 has been independently reproduced by a second research team. The findings are more credible with external confirmation than without it. If you run the harness on your own fleet and get different results, we want to know — file an issue with the JSONL output.

---

## What we don't claim

- We don't claim the lessons block is universally harmful. It helps on small (1.5B) and large (14B) models on specific task types.
- We don't claim Chump's cognitive-architecture modules (belief state, surprisal EMA, neuromodulation) are validated. Only the lessons block is systematically A/B tested. The other components are instrumented but not ablated.
- We don't claim the few-shot exemplar generalizes to all OSS models or all task classes. It worked once on one gap class. Treat it as an existence proof, not a shipping technique.
- We don't claim any of this constitutes consciousness, cognition, or anything beyond operationally-defined pass-rate on a task fixture.

---

## What's next

Open methodology questions:
- Does the aggregate harm signal (−10 to −16 pp) reproduce under the fixed EVAL-060 instrument? (EVAL-069 in progress)
- Does the task-class-aware gate hold at n≥100 under cross-family judges? (EVAL-030-VALIDATE queued)
- Does the few-shot exemplar technique transfer to harder gap classes? (COG-031 V10 held pending methodology clearance)

External replication of any finding is the highest-leverage thing the community can contribute.

The code is open. The fixtures are open. The harness is open. The evals that produced these findings are documented down to the exact `python3.12` command. Go break our results.

---

*Draft status: pending external review (Gemini architectural reviewer) before final publication. Not yet live. When published, URL will be added to docs/FINDINGS.md "How to cite" section.*
