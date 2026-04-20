# COG-031 Step 1 Result: Static prompt overlay loses to instruct-tuning prior on all three Together model families tested

**Date:** 2026-04-19 (V6, V7 evening)
**Status:** **Step 1 closed as empirically negative.** All three model families
            tested with the QwenCoder/chat-Instruct overlay defaulted to chat
            behavior anyway. The overlay's instructional tokens cannot
            outweigh Together-served Instruct models' post-training prior.
            Step 2 (few-shot exemplars + system-prompt injection) is the
            next pass; designed below.
**Scope:** dispatched `chump-orchestrator` subagents on `CHUMP_DISPATCH_BACKEND=chump-local`.

## What we tested

[`COG-031 step 1`](../../crates/chump-orchestrator) shipped in PR #190 as a
static model-shape detector + per-family overlay prepended to the dispatched-gap
user prompt. Overlay text for Qwen-Coder explicitly bans the V5 failure phrase
("Would you like me to..."), demands ship-or-blocker, declares "no user in
this session." Chat-Instruct overlay forces a first-action deadline by
iteration 5.

Three trials run after step 1 landed, identical orchestrator config, identical
overlay code in the binary (verified via `strings target/release/chump | grep
'AUTONOMOUS JOB'` = 3 occurrences):

| Trial | Model | Overlay applied | Outcome | Tool calls |
|---|---|---|---|---|
| V5 (control) | Qwen3-Coder-480B | none — pre-step-1 | "Would you like me to focus on a specific domain?" | ~30 |
| V6 | Qwen3-Coder-480B | QwenCoder | "I'm happy to help — let's set you up for success. What should I call you?" | ~90 |
| V7 | DeepSeek-V3.1 | DeepSeek (= chat-Instruct shape) | "What specific aspect of this gaps file are you interested in? Are you looking to: Add a new gap/task, Check the status..." | 17 |

All three failed; **none shipped a PR**.

## What the overlay actually did

It made the failure mode *worse*, not better, in two of the three trials.

- **V5 (no overlay)** — 30-ish tool calls, then a polite single-line meta question and exit.
- **V6 (overlay)** — 90 tool calls, deeper exploration, then a *more elaborate* chat-bot intro with a name request. The model spent more context on the prompt and came out *more* in chat mode, not less.
- **V7 (overlay)** — 17 tool calls (fastest), then a literal multiple-choice menu. DeepSeek-V3.1 flipped into chat mode almost immediately and produced the most chat-like terminal state of the three.

The overlay's directives (in V6 and V7) appear to have *reinforced* the model's
chat-shape pattern-matching rather than overridden it. More instructional
preamble = more "I'm being asked a question about an instruction" = more
chat-bot reply.

## Why this happened — informed guess

Sonnet 4.5 ships on the bare prompt because Anthropic explicitly trains for
agent-mode (Claude Code, Computer Use, MCP, the Agent SDK all share the same
"you are a job, not a chat partner; tools are real; ship and exit" contract).
That training is reinforced in post-training reward, not just in the prompt.

Together's catalog is trained primarily for chat benchmarks (MMLU, MT-Bench,
AlpacaEval) which reward "be a helpful conversational assistant." When a
Qwen3-Coder-480B or DeepSeek-V3.1 sees Chump's prompt, it pattern-matches to
"this is a coding question with extensive context" and produces the highest-
scoring response on the benchmarks it was trained for: a conversational
intro, a clarifying question, or a polished chat-bot menu.

A few hundred tokens of "you are an autonomous job" preamble cannot outweigh
billions of tokens of RLHF that taught "always end with 'Would you like me to...'".
The prior wins.

## Three paths forward — pick one for step 2

Listed in increasing cost / effectiveness:

### Path A — Few-shot exemplars in the prompt (cheapest)

Prepend 1-2 actual successful agent-loop traces (ours, from Sonnet runs we've
already shipped) into the user prompt. Show, don't tell.

> Example successful run for gap COMP-014:
> ```
> Iteration 1: read_file docs/gaps.yaml — found COMP-014 acceptance criteria
> Iteration 2: read_file src/cost_tracker.rs — found bug at line 142
> Iteration 3: patch_file src/cost_tracker.rs — fix
> Iteration 4: scripts/chump-commit.sh src/cost_tracker.rs -m "fix: ..."
> Iteration 5: scripts/bot-merge.sh --gap COMP-014 --auto-merge
> Final reply: PR #183
> ```
> Now do the same for gap COG-XXX.

In-context demonstrations are known to weight *more strongly* than instructional
preamble for instruct-tuned LLMs. Cost: ~500 extra prompt tokens per run, no
code change beyond the overlay function.

### Path B — System-prompt injection (medium)

Move the overlay from the user message into Chump's *system prompt*. The user
message is treated as "the question this turn"; the system message is treated
as "who you are and what mode you're in." Chat-Instruct training puts more
weight on the system message for behavioral framing.

Requires touching `src/agent_loop.rs` to thread an `extra_system_lines` arg
through `ChumpAgent::run`. Larger change but more architecturally correct.

### Path C — Fine-tune a small open-source model (most effective)

Take Llama-3.1-8B-Instruct, fine-tune on 100 successful Chump agent traces
from Sonnet runs. Cost: ~$50 on Together's fine-tune API or ~$10 on a
spot GPU. Result: a model that has the same agent-mode prior Anthropic
trained for, but free to run.

This is how Anthropic got Sonnet to honor the contract; no reason it
shouldn't work on any base model. The "rooftop" version of Chump probably
has a `chump-loop-8b` model card on Hugging Face.

## Recommendation

Start with **Path A (few-shot exemplars)** as step 2 — same overlay function,
just inject 1-2 trace examples instead of/alongside the directive text. Tests
the in-context-demonstration hypothesis cheaply (~$0.10 of Together credit
per trial). If Path A ships even one PR on a Together model, the autotuner
thesis is alive and we proceed to Path B (system-prompt) for production
robustness. If Path A also fails, jump straight to Path C (fine-tune) — that's
the unambiguous path.

## Cost ledger update

- V6 (Qwen3-Coder-480B): ~$0.10
- V7 (DeepSeek-V3.1, $0.6/M): ~$0.02
- Total Together credit consumed across V5+V6+V7: **~$0.20** of $5
- PRs shipped *by* Together (across V2-V7): **0**
- PRs shipped *from* iterating on this: **5** (#174, #178, #182, #185, #186, #190)

## Files

- `/tmp/chump-together-v{5,6,7}.log` — traces for all three Coder/DeepSeek trials
- `/tmp/chump-together-run-v{5,6,7}.sh` — launcher scripts
- `src/model_overlay.rs` (PR #190) — step 1 implementation, kept in tree (still
  used for Sonnet baseline = no overlay; harmless when overlay returns None)
- Predecessor: `docs/eval/COG-026-TOGETHER-DISPATCH-2026-04-19.md`
- Followup: this doc → step 2 design = Path A few-shot exemplars
