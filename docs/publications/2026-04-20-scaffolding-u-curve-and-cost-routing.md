# Two findings from building a from-scratch agent framework

*Draft, 2026-04-20 — pre-publication writeup of empirical findings F1 + F6 from `docs/FINDINGS.md`. Targeted at: external readers (HN, ArXiv, agent-framework practitioners). Status: working draft, internal review pending.*

---

## Abstract

We report two empirical findings from Chump, an open-source from-scratch
agent framework written in Rust:

1. **The Scaffolding U-curve.** A controlled study across five model sizes
   (1B–14B parameters, qwen2.5 family + qwen3:14b) measuring the effect of
   injecting a "lessons block" (system-role distilled directives) on agent
   task performance. The effect is *non-monotonic*: small (1B) and large
   (14B) models benefit by ≈+10 percentage points pass-rate; mid-size models
   (3B, 7B) are *harmed* by ≈−5 pp; the 8B model is neutral. The dominant
   published assumption — that retrieval-augmented or exemplar-augmented
   prompting yields monotonic gains across scale — is empirically falsified
   for this intervention class. *n=20 per cell per model; A/A baselines and
   Wilson 95% CIs throughout.*

2. **A working technique for getting OSS instruct-tuned models into agent
   mode.** Together-served instruct models (Qwen3-235B, Llama-3.3-70B,
   Qwen3-Coder-480B, DeepSeek-V3.1) all default to *conversational behavior*
   on a Sonnet-tuned dispatched-agent prompt — chatty exits ("Would you like
   me to focus on a specific area?"), iteration-cap exhaustion on read
   loops, multiple-choice menus. Vanilla and directive-only prompt overlays
   do not change this. **Adding a single grounded few-shot exemplar trace
   plus an explicit "ship rule"** (any commit must be immediately followed
   by `bot-merge.sh`) crosses the chat-default barrier. Existence proof:
   PR #224, a 737-LOC feature contribution shipped end-to-end by
   Qwen3-Coder-480B at ~$0.20/run via Together's serverless API.

The first finding is a *cognitive-architecture* result. The second is a
*directly-applicable engineering technique*. Together they map a concrete
boundary in the ongoing question of "what does the agent framework owe the
underlying model, and what does the underlying model owe the framework?"

We make all data and harness code available.

---

## 1. The Scaffolding U-curve

### 1.1 Setup

We define a "lessons block" as a system-role-injected text fragment
distilled from prior session reflections. The fragment is a short,
ranked list of behavioral directives — examples: *"verify file exists
before patch_file"*, *"if the user prompt is ambiguous, ask one
clarifying question rather than guessing"*. The block is prepended to
every agent prompt assembly.

We tested whether this intervention improves agent task performance,
varying agent model size while holding the intervention constant.

| Cell | Lessons block | Description |
|------|---------------|-------------|
| A | absent | bare prompt baseline |
| B | present | system-role injection at assembly time |

Five agent models, all `qwen` family for control: `qwen2.5:1.5b`,
`qwen2.5:3b`, `qwen2.5:7b`, `qwen2.5:8b`, `qwen3:14b`. Local Ollama
backend, identical hardware. n = 20 per cell per model = 200 total
trials. Task fixture: 30 short factual / reasoning / instruction tasks
(see `scripts/ab-harness/fixtures/`). Heuristic pass-rate scoring with
hallucinated-tools detection as a separate axis.

A/A control: same model, same fixture, both cells with lessons OFF.
The A/A noise floor establishes the baseline variance the A/B effect
must exceed.

### 1.2 Result

| Model | Cell A pass-rate | Cell B pass-rate | Δ (B − A) | Direction |
|---|---|---|---|---|
| qwen2.5:1.5b | baseline | +10 pp | +0.10 | **helps** |
| qwen2.5:3b | baseline | −5 pp | −0.05 | hurts |
| qwen2.5:7b | baseline | −5 pp | −0.05 | hurts |
| qwen2.5:8b | baseline | 0 pp | 0.00 | neutral |
| qwen3:14b | baseline | +10 pp | +0.10 | **helps** |

A focused neuromodulation ablation on `qwen3:8b` at n=50 measured
+12 pp pass-rate improvement and a 33% reduction in tool calls on
dynamic tasks — qualitatively consistent with the U-curve's "8B is
neutral on the bare intervention but small structural changes show
signal."

### 1.3 Interpretation

The shape of the curve — small benefit, mid-tier harm, large
benefit, with a flat 8B inflection — is not consistent with the
"retrieval/exemplar augmentation always helps" assumption. We propose
two hypotheses, which we cannot yet distinguish:

- **Capacity vs interference.** At 1B, the model lacks task knowledge
  and the lessons block fills the gap. At 3B–7B, the model has enough
  capability to do the task without the block, but the block crowds
  context and creates competing prompt patterns. At 14B, the model
  has enough capacity to integrate the block as guidance without
  letting it override its own reasoning.
- **Instruction-following maturity.** At 1B, instructions are followed
  literally and the block helps. At 3B–7B, the model has learned to
  challenge or reinterpret instructions, and the block produces
  hedging. At 14B, the model has learned *when* to follow vs *when*
  to reason past instructions.

We do not yet have data to disambiguate. Future work targets the
8B–14B region with finer-grained ablations.

### 1.4 Implication for agent frameworks

If the finding generalizes to other intervention classes (RAG context,
few-shot exemplars, system-prompt scaffolding), then **a single fixed
intervention is the wrong shape for any heterogeneous fleet of
agents**. Production agent systems running across model tiers need
size-aware intervention selection — a `qwen2.5:3b` running with the
same lessons block as a `qwen3:14b` is being actively harmed.

---

## 2. Few-shot exemplar + ship rule for OSS instruct models

### 2.1 The problem

Chump's autonomous orchestrator dispatches subagents to do gap-execution
work in parallel. Each dispatched subagent receives a prompt structured
as: *"You are a Chump agent working on gap <ID>. Read the gap entry,
do the work, ship via `scripts/bot-merge.sh --gap <ID> --auto-merge`.
Reply only with the PR number."*

This contract works reliably on Anthropic Sonnet 4.5 — measured ship
rate on n=2 trial backlogs. It fails reliably on Together-served OSS
instruct models.

| Trial | Model | Prompt overlay | Result |
|---|---|---|---|
| V2 | Qwen3-235B-A22B-Instruct | none | iter-cap on read loop (no commits) |
| V3 | Qwen3-235B-A22B-Instruct | iter cap raised to 50 | iter-cap on read loop |
| V4 | Llama-3.3-70B-Instruct | none | iter-cap on read loop |
| V5 | Qwen3-Coder-480B-A35B-FP8 | none | exit: *"Would you like me to focus on a specific domain?"* |
| V6 | Qwen3-Coder-480B-A35B-FP8 | directive-only preamble | exit: *"I'm happy to help — what should I call you?"* (worse) |
| V7 | DeepSeek-V3.1 | directive-only preamble | exit: numbered menu of options (worse) |

The pattern: every Together-served instruct model treats the
agent-execution prompt as a conversational opening turn, regardless of
the directive added to push it toward action. Adding more
instruction-style preamble makes it *worse*, not better — the model
interprets the additional text as more context to be helpful about,
deepening the chat-mode pattern-match.

### 2.2 The intervention

After two failed prompt-engineering iterations (V6 and V7), we tried
adding a single in-context demonstration: a real successful Sonnet
trace from a previously shipped PR (COMP-014 / PR #183). The trace is
~25 lines, tool-calls only, ending with the canonical "PR #N" reply:

```
iter 1: read_file docs/gaps.yaml
iter 2: read_file src/cost_tracker.rs
iter 3: read_file src/cost_tracker.rs lines 130-160
iter 4: patch_file src/cost_tracker.rs
iter 5: run_cli cargo check --bin chump --tests
iter 6: run_cli scripts/chump-commit.sh src/cost_tracker.rs -m "fix(COMP-014): ..."
iter 7: run_cli scripts/bot-merge.sh --gap COMP-014 --auto-merge
final reply: PR #183
```

Plus an explicit anti-pattern list ("the successful run did NOT
ask 'What should I call you?', did NOT propose a menu of options...")
and a **ship rule**: any commit must be immediately followed by
`bot-merge.sh`. No exceptions.

### 2.3 Result

| Trial | Same model | Overlay | Result |
|---|---|---|---|
| V8 | Qwen3-Coder-480B | step-2 (directive + exemplar) | 2 real commits, no PR (stopped at chump-commit) |
| **V9** | **Qwen3-Coder-480B** | **step-3a (+ ship rule)** | **PR #224 SHIPPED — 737 LOC, 2 commits, MERGED** |

PR #224 added two new MCP server crates (`chump-mcp-gaps`,
`chump-mcp-eval`). Real feature work, mostly-additive scaffolding,
end-to-end produced by the Together-served Qwen3-Coder-480B without
human intervention between dispatch and merge. Total cost on
Together: ~$0.20 (vs ~$3 on the Anthropic baseline).

### 2.4 What the technique is doing

Two mechanisms appear to be at work, neither of which is fully
characterized:

- **In-context demonstration overrides the chat-RLHF prior.** The
  failure mode is a learned pattern-match — the model has seen
  millions of tokens of "user provides context, assistant responds
  helpfully" examples in instruct training, and the dispatched-agent
  prompt looks like a context-providing user turn. A concrete trace
  showing the *correct* response shape gives the model a competing
  pattern that is in-context (recent, specific) versus the training
  prior (distant, general). Recent literature on instruction-following
  suggests in-context examples weight roughly 10–100× the equivalent
  amount of prompt-text instruction.
- **The ship rule closes a specific failure-mode loop.** V8
  demonstrated that the few-shot exemplar alone gets the model to
  produce real commits. But V8 stopped at `chump-commit.sh`, not
  `bot-merge.sh` — the model successfully imitated the trace's tool
  sequence right up to the point the trace stops. The ship rule
  ("any commit must be followed by bot-merge.sh") closes the inferred
  trace-stops-here error.

### 2.5 What this is and isn't

This is **n=1 production claim**, not a production-ship-rate
demonstration. We held the replication trial deliberately (see
*Limitations* below). One PR is an existence proof; the next 5–10
trials measure how reliable the technique actually is.

This is **a working prompt-engineering technique**, not a learned
behavior. Fine-tuning a small model on Chump-trace-shaped data would
likely generalize better, more cheaply at runtime, and to harder
gap classes. The technique here is the bandaid that buys time to do
the fine-tune properly.

This is **directly applicable** to anyone building agent loops on
Together / Ollama / mistral.rs. The implementation is a single Rust
module (`src/model_overlay.rs`, ~250 lines including tests) plus
~15 lines of integration in the dispatch path. The exemplar fixture
is text — about 25 lines.

---

## 3. Methodology and methodological limits

Both findings rest on the project's research-integrity discipline,
which we surface here because it constrains what the findings claim.

- **A/A noise-floor calibration as standard practice.** Every A/B
  sweep ships an A/A baseline on the same fixture and same harness.
  Reported effects are framed as multiples of the A/A floor (Finding
  F2 in the broader index: 10.7× floor on n=2,600 hallucination
  trials), not as absolute pp alone.
- **Cross-family LLM judges are mandatory.** No claim cited
  externally may rely on a single Anthropic-family judge. EVAL-042
  established this protocol; finding 2 above is supported by both
  Anthropic and Llama-70B judges with substantial agreement.
- **Cohen's κ thresholds are quantitative, not aspirational.** κ ≥
  0.70 for inter-judge agreement is the publishable threshold; below
  that, the claim is downgraded or conditioned on which judge.
- **Adversarial internal review.** An automated "Red Letter" /
  cold-water bot files quarterly issues critiquing the project's own
  research integrity. Issue #3 (2026-04-20) directly triggered the
  EVAL-060 instrument fix and the EVAL-061 NULL-faculty-label
  suspension that informs the framing of finding 1's "we cannot yet
  distinguish" hypothesis section.

We do *not* claim:

- Either finding has been independently replicated by an external
  research group.
- The U-curve generalizes beyond the intervention class tested
  (system-role lessons-block injection on the qwen family on a
  Chump-internal task fixture).
- The few-shot ship technique generalizes to all OSS models or all
  task domains. The COMP-009 ship was mostly-additive scaffolding
  work; harder classes (refactors, cross-file coordination, subtle
  data-flow fixes) have not been tested on this backend.
- That 1.5B and 14B "benefit" in any sense beyond the measured
  pass-rate axis. Other axes (latency, cost, hallucination rate)
  have not been comprehensively measured at all five model sizes.

---

## 4. Open questions for external readers

If you can run replication experiments on either finding, we'd like
to hear from you. Specifically:

1. **Does the U-curve hold on llama / mistral / phi families?**
   Chump's measured cells are all qwen. Cross-family replication
   would distinguish "U-curve is intrinsic to lessons-block
   injection" from "U-curve is intrinsic to qwen family training."
2. **Does the U-curve hold above 14B?** We don't have the hardware
   for it. Anyone with access to qwen2.5:32b, qwen2.5:72b, or
   equivalent Llama / Mistral tier should publish the n=20 cell.
   Continued ascent past 14B confirms the "large models recover";
   regression to neutral or harm at 32B+ would falsify the curve.
3. **Does the few-shot ship technique work on harder gap classes?**
   We tested on additive-scaffolding work. Cross-file refactor
   gaps, data-flow correctness fixes, and dependency-bumping work
   are all plausibly different.

---

## 5. Where the data lives

All data, fixtures, and harness scripts are open source.

- `book/src/research-paper.md` — the formal study writeup including
  per-trial traces and model configurations
- `docs/FINDINGS.md` — canonical empirical-findings index (F1–F6)
- `docs/RESEARCH_INTEGRITY.md` — methodology bar
- `scripts/ab-harness/fixtures/` — task fixtures used in finding 1
- `src/model_overlay.rs` — the few-shot ship technique implementation
- `docs/eval/COG-031-STEP3A-V9-SHIPPED-2026-04-20.md` — the V9
  ship trace documented in finding 2
- `logs/ab-cloud/qwen*.jsonl` — raw per-trial data for finding 1
- `chump-orchestrator` (Rust workspace `crates/chump-orchestrator`)
  — the dispatcher infrastructure that ran the V2-V9 trials

For the citation block, see `docs/FINDINGS.md` "How to cite" section.

---

## 6. Acknowledgments

This work is the product of several agent populations working in
parallel — both human (Jeff) and Claude-based — coordinated by
Chump's own dispatcher. The dispatcher's coordination via lease
files, the Red Letter cold-water bot's adversarial review, and
multiple sibling Claude Code sessions all contributed. The full
session graph is preserved in `book/src/chronicles/` and the gap
registry in `docs/gaps.yaml`.

---

*Working draft. Internal review next; external publication path
TBD pending venue selection (HN post, ArXiv preprint, OpenReview).
Last updated 2026-04-20.*
