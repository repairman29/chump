# COG-031 Step 2 V8 result: few-shot exemplar broke the chat-default — Qwen3-Coder-480B produced correct gaps.yaml maintenance commits independently matching what Anthropic-dispatched agents shipped

**Date:** 2026-04-19
**Status:** **Positive empirical result.** Few-shot exemplar shifted Qwen3-Coder-480B
            from chat-default behavior to actual command execution + commit creation.
            V8 produced 2 commits that V5/V6/V7 (same model, weaker overlays) could
            not produce. One of those commits was independently verified correct: it
            matched what concurrent Anthropic-dispatched agents shipped to main while
            V8 was running.
**Scope:** dispatched `chump-orchestrator` subagents on `CHUMP_DISPATCH_BACKEND=chump-local`.

## The trial

**Setup identical to V5-V7** (same model, same orchestrator config, same gap backlog,
same `--max-parallel 2`), only difference is the COG-031 step-2 overlay (PR #197 / commit
69b0ab4): static directive + ~25-line few-shot exemplar showing canonical Chump tool-use
shape (`read_file → patch_file → chump-commit.sh → bot-merge.sh → terminal "PR #N"`),
ending with explicit anti-patterns ("Notice what the successful run did NOT do: no 'What
should I call you?', no 'Would you like me to...', no preamble").

The exemplar is grounded in a real shipped PR (COMP-014 / PR #183) so the model sees a
concrete trace rather than abstract instructions.

## Behavioral shift (vs V5/V6/V7)

| Trial | Overlay | Tool-call mix | Terminal state | Commits |
|---|---|---|---|---|
| V5 | none | 100% read_file | "Would you like me to focus on a specific domain?" | 0 |
| V6 | step-1 directive | 100% read_file | "I'm happy to help — what should I call you?" | 0 |
| V7 | step-1 directive (DeepSeek family) | 100% read_file | multiple-choice menu | 0 |
| **V8** | **step-2 directive + few-shot exemplar** | **63% read_file, 37% run_cli, 0% patch_file** | "no changes in src/reflection.rs to commit" | **2** |

The shift from V5-V7's pure-read behavior to V8's mix of `run_cli` (`git`, `cargo`,
status checks) + actual commit creation is substantial. V8 is the first non-Anthropic
trial that produced *any* git commits.

## What V8 actually did

V8 dispatched two subagents (COMP-008 and COMP-009 worktrees). One subagent (COMP-008
worktree) produced two commits:

### Commit 64affde — clean, correct

> `chore(gaps): close COMP-011a (PR #193) + INFRA-COST-CEILING (PR #187)`
>
> Updated `docs/gaps.yaml` to mark COMP-011a (`status: open` → `done` +
> `closed_date: "2026-04-20"` + `closed_pr: 193`) and INFRA-COST-CEILING (same fields,
> PR #187). Both PRs *had actually shipped to main* earlier today.

**Independent verification:** while V8 was running, sibling Anthropic-dispatched agents
shipped the *same* closures to main with byte-identical fields. V8's diff would have
been a no-op rebase. Two different agent populations producing the same correct answer
on the same maintenance task is a meaningful positive signal — not just "the model
shipped *something*" but "the model shipped *what was actually right*."

### Commit 118760e — work happened, commit message wrong

> `chore(gaps): close 3 gaps shipped 2026-04-20 (PRs #195-196, #198)`
>
> Diff actually contained: **8 gap-ID renumbers** + **3 status-done updates**. The 3
> status updates match what the message claims; the 8 renumbers don't.

This is a *different* failure mode worth tracking: the model's commit message generation
under-reported the actual diff. Mismatched messages are a known issue with chat-RLHF
models (they generate plausible-sounding messages from a templated pattern rather than
faithfully summarizing the diff). Step 3 of COG-031 should add a "verify message ≈ diff"
post-commit check.

### COMP-009 subagent — produced 0 commits

The second V8 subagent ran the same overlay on the same model but produced no commits.
Trace inspection shows it stayed in chat-default mode, similar to V7. So V8's effective
ship rate was 1/2 = 50%, not 100%.

## Headline

> **The few-shot exemplar broke the chat-default barrier.** Qwen3-Coder-480B,
> which produced 0 commits on the same task in V5/V6/V7, produced 2 commits
> in V8 — one of them independently verified correct against what production
> Anthropic-dispatched agents shipped to main. The autotuner thesis is alive.

Three caveats:
1. V8 is **n=1 trial, 1 of 2 subagents shipped** — needs replication on a wider
   workload sample to claim a real ship rate.
2. Neither commit was pushed via `bot-merge.sh` — the model stopped at "commit," didn't
   reach "push + open PR." Step 3's exemplar should walk through `bot-merge.sh`
   explicitly, not just chump-commit.
3. The commit-message mismatch on 118760e shows step 3 needs message-vs-diff verification.

## Step 3 design (informed by V8)

1. **Stronger exemplar** — extend the trace through `bot-merge.sh --auto-merge` and
   show the terminal "PR #N" reply tied to the orchestrator's pickup. Currently the
   exemplar stops at `chump-commit.sh`; V8 stopped exactly there too.
2. **Commit-message-vs-diff check** — post-commit hook (or in-loop verifier) that
   refuses to push commits whose message doesn't summarize the diff. Catches the
   118760e failure mode.
3. **System-prompt injection** (Path B from step-1 result doc) — move the directive
   into Chump's system prompt instead of the user message. The exemplar can stay in
   user-message context for in-context demonstration.
4. **Replication trials** — n≥5 V8-equivalents on different gaps, measure actual ship
   rate (PR opened, not just commit). One commit on n=1 is positive but not yet
   "rooftop" — a replicated 30%+ ship rate is.

## Cost ledger update

- V8 (Qwen3-Coder-480B with step-2 overlay): **~$0.15** of $5 Together credit
- Cumulative V5-V8: **~$0.35** of $5
- PRs shipped *by* Together: still 0 (V8 commits weren't pushed)
- PRs shipped *from* iterating on this: now **9** (#174, #178, #182, #185, #186, #190, #194, #197, this doc forthcoming)
- **Real commits authored by Qwen3-Coder-480B + COG-031 step-2 overlay: 2** (1 verifiably
  correct, 1 with message defect)

## Files

- `/tmp/chump-together-v8.log` — full trace
- `/tmp/chump-together-run-v8.sh` — launcher
- Worktree `comp-008/` — branch `claude/comp-008` carries the 2 V8 commits, retained
  as evidence (do not push as PR; sibling agents already shipped the same closures via
  PR #193/#195/#196/#198)
- Step-1 result: `docs/eval/COG-031-STEP1-RESULT-2026-04-19.md` (PR #194)
- Step-2 implementation: PR #197 (commit 69b0ab4)

## What changed since the morning's COG-026 conclusion

This morning's COG-026 finding closed as "Together's Instruct family models cannot
drive Chump's agent loop end-to-end" with the recommendation "revert to Anthropic for
unattended runs; pursue COG-031 autotuner." That conclusion stands for vanilla prompts.

The new finding from V8: **with the right overlay (step-2 few-shot exemplar),
Together-served Qwen3-Coder-480B can produce real commits** — not at production-grade
ship rates yet, but at non-zero rates where the same model with weaker overlays produced
exactly zero. The autotuner is no longer hypothesis; it's an early-stage but working
mechanism.

The cost-routing thesis is back on the table for evening sessions, with COG-031 step-3
work as the next 3-5 day investment.
