# COG-026 Final Result: Together Instruct-family models all default to chat behavior on Chump's prompt — autotuner (COG-031) is the answer

**Date:** 2026-04-19 (V2-V4 morning, V5 evening)
**Status:** **Closed.** Empirical answer in. Picking the right Together model isn't the lever; prompt
            shape is. Filed COG-031 (model-shape autotuner) as the path forward.
**Scope:** `CHUMP_DISPATCH_BACKEND=chump-local` orchestrator-dispatched subagents only. Together
            remains the right backend for sweeps + single-shot generation; only multi-turn agentic
            convergence is broken.

## What we tested

The COG-025 dispatch-backend pluggability landed earlier today, letting `chump-orchestrator`
route dispatched subagents through `chump --execute-gap <GAP-ID>` instead of external `claude`.
With `OPENAI_API_BASE` pointed at `https://api.together.xyz/v1` and `OPENAI_MODEL` set to a
Together-served large model, the subagent loop runs on Together's serverless inference instead
of Anthropic.

Four sequential autonomy runs, identical orchestrator config (`--max-parallel 2 --no-dry-run --watch`),
identical wide `CHUMP_CLI_ALLOWLIST` + empty `CHUMP_TOOLS_ASK` + `CHUMP_DISABLE_ASK_JEFF=1`:

| Run | Model | Class | iter cap | Outcome |
|---|---|---|---|---|
| V2 | `Qwen/Qwen3-235B-A22B-Instruct-2507-tput` | chat | 25 | iter-cap on read loop. 0 PRs. |
| V3 | `Qwen/Qwen3-235B-A22B-Instruct-2507-tput` | chat | 50 | iter-cap on read loop. 0 PRs. |
| V4 | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | chat | 50 | iter-cap on read loop. 0 PRs. |
| **V5** | **`Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8`** | **coder** | **50** | **Chatty exit: "Would you like me to focus on a specific domain?". 0 PRs.** |

Anthropic Sonnet 4.5 baseline (PR #167 from morning autonomy crusade) shipped end-to-end on
the same prompt + same orchestrator + same gap-picker, well under the 25-iter default. So the
prompt + tooling are not the bottleneck — the model determines whether the loop converges to
action.

## Failure modes

### V2/V3/V4 — chat models: "thorough exploration"

Per-iteration tool-use traces in `/tmp/chump-together-v{2,3,4}.log` show both Qwen3-235B-Instruct
and Llama-3.3-70B-Instruct spending the entire iteration budget in an exploration phase: long
chains of `run_cli` (rg / cargo / git / ls), `episode`, and `memory_brain` reads, interleaved
with `notify` / `task` planning calls, but never converging to a `patch_file` / `write_file` /
`git_commit` / `bot-merge.sh` action. By iteration 50 the agent is still re-reading files it
already loaded in the first 10 iterations.

This is not a tool-permission failure (V2's allowlist gap was fixed in V3+V4) and not a
context-window failure (Qwen3-235B has 256k context; runs never approach it). It is a
**convergence failure** — chat-RLHF models keep hedging by gathering more context instead of
committing to a write.

### V5 — coder model: "helpful conversational summary"

The Qwen3-Coder-480B trial was the most informative because it failed *differently*. After
~18 `read_file` calls in a row, the model produced a polished bullet-list summary of
`docs/gaps.yaml` and ended with:

> *"Would you like me to focus on any specific domain or priority level for deeper analysis? Or
> would you prefer I work on a particular gap from this list?"*

That's not iter-cap exhaustion — it's **the model treating an autonomous-job prompt as a
helpful Q&A turn**. The coder-RLHF didn't override the underlying instruct-tuning. The model
exited cleanly, the orchestrator marked the dispatch complete, and 0 work shipped.

## Root cause (now empirically supported)

Three Together model classes — chat-235B, chat-70B, coder-480B — three distinct failure modes,
**one root cause**: Together's Instruct family models all default to "be a helpful conversational
assistant" on Chump's current prompt regardless of post-training specialty. The prompt was
implicitly tuned for Sonnet-class instruction-following ("read what you need, then ship via
`bot-merge.sh`") and that contract simply isn't honored by Together's lineup.

This is not a Together-specific knock; it's a generalization gap. The same failure shape would
likely appear on most non-Anthropic instruct-tuned LLMs run on the same prompt. The Sonnet
baseline isn't proof of "Sonnet is uniquely capable" — it's proof of "Chump's prompt happens to
match Sonnet's tuning."

## Decision

**Closed COG-026 as: empirically negative. Picking the right Together model is not the lever.**

The path forward is **COG-031** (filed as a follow-up gap): a model-shape autotuner in
`chump-orchestrator` that detects the dispatched-subagent's behavior shape in the first 3
iterations and mutates the prompt to match. The autotuner persists per-model overlays to
`chump_model_profiles` so subsequent runs of the same model start with the calibrated prompt.

If COG-031 gets *any* non-Anthropic Together model to ship at ≥50% rate where the vanilla
prompt fails 0%, that result is publishable. It also makes Chump genuinely model-portable —
"runs on whatever LLM you have" instead of every other agent framework's "use Sonnet."

### Concrete near-term actions

- **Orchestrator dispatch backend (this week):** revert to `claude` (Anthropic Sonnet 4.5)
  for any unattended overnight run. Confirmed shipping. Worth the spend until COG-031 lands.
- **Sweeps + eval harness:** keep Together. Single-shot generation works fine — the failure
  mode is multi-turn agentic convergence specifically.
- **No further "try another Together model" trials.** We have enough data. The next move is
  building COG-031, not running V6/V7 on more Together model IDs.

## Cost ledger

- Anthropic spend on the four Together runs: **$0** (no Anthropic calls — that was the point).
- Together spend across V2+V3+V4 (free serverless tier): **$0**.
- Together spend on V5 (paid `$2/M` Qwen3-Coder-480B): **~$0.05** (truncated output, mostly input tokens).
- Total wall-clock across V2-V5: **~3.5 hours**.
- PRs shipped *by* Together: **0**.
- PRs shipped *from* the iteration that came out of this test: **3** (#174 rules-inject,
  #178 max-iter env, #182 COG-026 interim doc).

So the headline result is "Together didn't ship code on the agent loop, but the iteration
produced three real infrastructure improvements that benefit the Anthropic path too **and**
gave us the empirical foundation to file COG-031 with confidence." Net positive on
infrastructure; the cost-routing thesis is paused pending COG-031.

## Files

- `/tmp/chump-together-v2.log` — Qwen3-235B-Instruct chat @ iter=25 trace
- `/tmp/chump-together-v3.log` — Qwen3-235B-Instruct chat @ iter=50 trace
- `/tmp/chump-together-v4.log` — Llama-3.3-70B-Instruct chat @ iter=50 trace
- `/tmp/chump-together-v5.log` — Qwen3-Coder-480B coder @ iter=50 trace (chatty exit, not iter-cap)
- `/tmp/chump-together-run-v{1,2,3,4,5}.sh` — launcher scripts (env config preserved)
- PRs: #167 (Anthropic baseline shipped), #174 (rules-inject), #178 (max-iter env),
  #182 (this doc, interim version)
- Followup gap: **COG-031** (model-shape autotuner) — the actual answer
