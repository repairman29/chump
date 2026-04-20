# COG-026 Interim Result: Together general-purpose chat models fail Chump's agent loop; coder models still untested

**Date:** 2026-04-19
**Status:** **Interim, not closed.** Two general-purpose chat models failed; the hypothesis-defining
            test (an action-oriented coder model) has not yet been run. See "Next trial" at bottom.
**Scope:** `CHUMP_DISPATCH_BACKEND=chump-local` orchestrator-dispatched subagents only. Has no
bearing on Together's usefulness for sweeps, eval harnesses, or single-shot generation.

## What we tested

The COG-025 dispatch-backend pluggability landed earlier today, letting `chump-orchestrator`
route dispatched subagents through `chump --execute-gap <GAP-ID>` instead of external `claude`.
With `OPENAI_API_BASE` pointed at `https://api.together.xyz/v1` and `OPENAI_MODEL` set to a
Together free-tier large model, the subagent loop runs on Together's serverless inference at
$0/token instead of Anthropic.

Three sequential autonomy runs, identical orchestrator config (`--max-parallel 2 --no-dry-run --watch`),
identical wide `CHUMP_CLI_ALLOWLIST` + empty `CHUMP_TOOLS_ASK` + `CHUMP_DISABLE_ASK_JEFF=1`:

| Run | Model | `CHUMP_AGENT_MAX_ITER` | Outcome |
|---|---|---|---|
| V2 | `Qwen/Qwen3-235B-A22B-Instruct-2507-tput` | 25 (default) | Both subagents `Exceeded max iterations (25)`. 0 PRs. |
| V3 | `Qwen/Qwen3-235B-A22B-Instruct-2507-tput` | 50 (via PR #178) | Both subagents `Exceeded max iterations (50)`. 0 PRs. |
| V4 | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | 50 | Both subagents `Exceeded max iterations (50)`. 0 PRs. |

Anthropic Sonnet 4.5 baseline (V4 of the morning autonomy crusade) shipped PR #167
end-to-end on the same prompt + same orchestrator + same gap-picker, well under the 25-iter
default. So the prompt + tooling are not the bottleneck — the cap is breached because the model
never converges to action.

## Failure mode (consistent across all three runs)

Looking at the per-iteration tool-use traces in `/tmp/chump-together-v{2,3,4}.log`, both Qwen
and Llama spend the entire iteration budget in an exploration phase: long chains of `run_cli`
(rg / cargo / git / ls), `episode`, and `memory_brain` reads, interleaved with `notify` /
`task` planning calls, but never converging to a `patch_file` / `write_file` / `git_commit` /
`bot-merge.sh` action. By iteration 50 the agent is still re-reading files it already loaded
in the first 10 iterations.

This is not a tool-permission failure (V2's allowlist gap was fixed in V3+V4) and not a
context-window failure (Qwen3-235B has 256k context; runs never approach it). It is a
**convergence failure** — the model keeps hedging by gathering more context instead of
committing to a write.

## Why bumping the cap doesn't fix it

Going 25 → 50 in V3 produced the same outcome: still no PR. Trace inspection shows the
exploration phase scales roughly linearly with the cap — when given more iterations, the
agent uses them on more reads, not on first-action commitment. There is no convergence
inflection point inside the 50-iter budget. Bumping to 100 would likely cost more without
shipping more.

The Anthropic baseline ships in 8–18 iterations on the same prompt, so there is no
architectural reason a competent model should need anywhere near 50.

## Hypothesis (to be confirmed by COG-026 follow-ups, not by this run)

The Chump agent system prompt + injected `CHUMP_DISPATCH_RULES.md` + lessons block + per-gap
briefing collectively assume a Sonnet-class instruction-following profile: "read what you
need, then ship via `bot-merge.sh`." Together's free-tier models appear to interpret the
preamble as "do all the reading first, then maybe later think about shipping" — a depth-first
exploration strategy that does not converge inside any reasonable iter budget.

Two non-exclusive paths to validate this:

1. **Prompt rewrite for non-Anthropic models.** Add an explicit "first-action deadline"
   directive ("commit your first patch_file by iteration 5 or explain why you can't") and a
   stronger "stop reading, start writing" hint. If this lands a Together-model PR, the issue
   was prompt-shape mismatch.

2. **Smaller / instruction-tuned model.** Try `Qwen2.5-7B-Instruct-Turbo` or
   `meta-llama/Llama-3.3-8B-Instruct-Turbo`. Smaller models are cheaper to swap in and the
   8B/7B Instruct variants are heavily RLHF'd toward action-completion. If they ship and
   235B/70B don't, the failure is "instruction-tuning shape" rather than raw capability.

## Decision (this week)

- **Orchestrator dispatch backend:** revert to `claude` (Anthropic Sonnet 4.5) **for any
  unattended overnight run**. Confirmed shipping. Worth the spend until COG-026 follow-ups
  land.
- **Sweeps + eval harness:** keep Together. Single-shot generation works fine — the failure
  mode is multi-turn agentic convergence specifically.
- **One more attended `chump-local` trial before declaring negative.** See "Next trial."

## Next trial — V5 with a coder-tuned model

The two failures (Qwen3-235B-Instruct, Llama-3.3-70B-Instruct) are both *general-purpose
chat assistants*. Their post-training optimizes for "be thorough and helpful" — exactly the
shape of behavior we observed (long exploration before any action). We have not yet tested
the model class that is purpose-trained for code action.

**Pick: `Qwen/Qwen2.5-Coder-32B-Instruct`** (Together free tier).

Why this is the right next test, not just "another model":
- *Different post-training objective.* Coder-Instruct models are RLHF'd toward "produce a
  diff, not commentary." That's the exact behavior shape the agent loop needs.
- *Smaller is better here.* 32B vs 235B/70B means ~3× faster iterations and tighter
  feedback loops. If the issue is convergence-shape, smaller is fine.
- *Same family as a known failure (Qwen).* Controls for "Qwen tokenization or chat-template
  weirdness." If 235B-Instruct fails and 32B-Coder ships, post-training is the variable.

If V5 ships a PR: the cost-routing thesis is alive — pick a coder model per workload class,
keep going. If V5 also exhausts iterations: file as confirmed negative, prompt-rewrite
becomes the only remaining path, and we close COG-026 with a real "general-shape problem"
finding rather than just "two models we tried didn't work."

Other candidates to keep in reserve (run only if V5 is ambiguous, not all-fail):
- `deepseek-ai/DeepSeek-V3` — different lineage, strong instruction-following
- `NousResearch/Hermes-3-Llama-3.1-405B-Turbo` — heavy action-RLHF on Llama base
- `deepseek-ai/DeepSeek-R1` — reasoning model; might over-think OR might reason itself
  toward "ship now." Worth one trial only if V5 is interesting.

## Cost ledger

- Total Anthropic spend on the three Together runs: $0 (no Anthropic calls — that was the
  point of the test).
- Total Together spend: $0 (free tier).
- Total wall-clock across V2 + V3 + V4: ~3 hours.
- PRs shipped by Together: 0.
- PRs shipped by the COG-027 + COG-025 fixes that came out of this test: 2 (#174, #178).

So the headline result is "Together didn't ship code, but the iteration produced two real
infrastructure improvements that benefit the Anthropic path too." Net positive on
infrastructure, net zero on the cost-routing thesis.

## Files

- `/tmp/chump-together-v2.log` — Qwen3-235B @ iter=25 trace
- `/tmp/chump-together-v3.log` — Qwen3-235B @ iter=50 trace
- `/tmp/chump-together-v4.log` — Llama-3.3-70B @ iter=50 trace
- `/tmp/chump-together-run-v{1,2,3,4}.sh` — launcher scripts (env config preserved)
- PRs: #167 (Anthropic baseline shipped), #174 (rules-inject), #178 (max-iter env)
