# COG-031 Step 3a V9 result: first end-to-end Together-routed PR shipped (PR #224) — cost-routing track crosses production threshold

**Date:** 2026-04-19 late / 2026-04-20 early
**Status:** **Positive single-trial result (n=1).** Qwen3-Coder-480B on Together
            shipped a 737-line feature PR end-to-end through Chump's orchestrator.
            Not a production claim — n=1 isn't that. But it's a real existence
            proof that the cost-routed path *can* ship, which V2-V8 could not
            establish.
**Scope:** dispatched `chump-orchestrator` subagents on
            `CHUMP_DISPATCH_BACKEND=chump-local`.

## The result

**PR #224 — `feat(COMP-009): add chump-mcp-gaps and chump-mcp-eval MCP servers`**

```
number:    224
state:     MERGED
mergedAt:  2026-04-20T05:49:27Z
size:      +737 / -0
commits:   2
  - feat(COMP-009): add chump-mcp-gaps and chump-mcp-eval MCP servers
  - chore(COMP-009): update Cargo.lock for chump-mcp-gaps and chump-mcp-eval
backend:   chump-local (Together)
model:     Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8
overlay:   COG-031 step 3a (directive + few-shot exemplar + SHIP RULE + recovery hint)
```

Not a doc PR, not a gap closure — **two new MCP server crates**, real feature
work, landed on main without human intervention after the V9 orchestrator
dispatched. The gap (COMP-009) was picked by `chump-orchestrator`, dispatched
to `claude/comp-009` worktree with `CHUMP_DISPATCH_BACKEND=chump-local`, driven
by the Qwen3-Coder-480B API through Chump's own agent loop, ran the gap work,
committed via `chump-commit.sh`, shipped via `bot-merge.sh --auto-merge`, and
the orchestrator's monitor recorded it:

```
=== monitor summary (2 entries) ===
  STALLED   claude/comp-008  (no PR within soft deadline)
  SHIPPED   claude/comp-009  PR #224
shipped=1  ci_failed=0  stalled=1  killed=0  spawn_failures=0
```

## The overlay that made it ship

The full overlay chain (directive → few-shot trace exemplar → SHIP RULE →
RECOVERY hint) lives in `src/model_overlay.rs`. For QwenCoder specifically:

1. **Directive (step 1, #190/#197):** "AUTONOMOUS JOB, NOT CHAT. No user in
   this session to answer questions. Do NOT end with 'Would you like me to…'"
2. **Few-shot exemplar (step 2, #197):** ~25-line trace of a real shipped PR
   (COMP-014 / PR #183) showing `read_file → patch_file → chump-commit.sh →
   bot-merge.sh → terminal "PR #N"`.
3. **SHIP RULE (step 3a, #216):** "The MOMENT you have made any commit, your
   VERY NEXT tool call MUST be `bot-merge.sh`. No exceptions."
4. **RECOVERY hint (step 3a, #216):** "If there's genuinely no change to make,
   write a doc/spec file as the patch, commit, and ship anyway. 'Nothing to
   commit' is never an acceptable terminal state."

Each step addressed a specific failure mode from the prior trial:

| Step added in | Fixed failure mode from | How |
|---|---|---|
| Step 1 directive | V2/V3/V4 chat-out | "AUTONOMOUS JOB" preamble |
| Step 2 exemplar | V5/V6/V7 chat-out ("Would you like me to…") | Concrete trace of success shape |
| Step 3a SHIP RULE | V8 stopped at chump-commit | Explicit "commit → bot-merge immediately" rule |

## Cost snapshot

- V9 trial cost on Together (Qwen3-Coder-480B at $2/M input): ~$0.20
- Equivalent PR on Anthropic Sonnet 4.5: ~$3.00
- **Cost reduction: ~15×** (per PR, at this model size and overlay weight)
- Total Together credit burned across V2-V9: ~$0.55 of the $5 starting credit

## What n=1 does and does not establish

**Does establish:**
- The overlay mechanism works end-to-end at least once. Before V9, Chump had
  never shipped a production PR through a non-Anthropic backend.
- Qwen3-Coder-480B can faithfully follow a long multi-step prompt when the
  trace shape is anchored by a real exemplar.
- `bot-merge.sh --auto-merge` survived a Together-backed dispatch without
  breaking anything on the orchestrator or the merge queue side.

**Does not establish:**
- A reliable ship rate. The same run had 1 stalled subagent (COMP-008) alongside
  the shipped one (COMP-009). At 50% single-run ship rate we have no production
  claim — just existence.
- Stability across gap classes. COMP-009 was "add two MCP server crates," a
  mostly-additive scaffolding task. Harder gaps (refactors, cross-file
  coordination, data-flow fixes) haven't been tested on this backend.
- Reproducibility. Same prompt + same model + same overlay could flip to
  stalled on the next run. Single-trial existence results are a starting
  line, not a conclusion.

## Deliberate hold: V10 replication

The natural next step is to run V10 as a replication trial. I am holding on
that tonight for a reason orthogonal to COG-031: Red Letter #3 (commit
d4d77e4) filed a research-integrity critique of the binary-mode ablation
harness the sibling agents have been closing EVAL gaps against. Adding more
Together dispatches into the pool while the EVAL harness is on fire would
contribute to the backlog pressure that's driving methodology-first-speed-
second commits. Better to let EVAL-060 (methodology fix) and EVAL-061
(NULL-faculty decision) clear first, then replicate V9 with clean space
and a real n≥5 trial budget.

## Context vs the sibling-agent work this week

COG-031 is orthogonal to the EVAL methodology concerns in Red Letter #3.
The step-3a overlay + V9 ship are a working-mechanism result on the
*dispatch backend* dimension — cost per PR — not on the *faculty validation*
dimension that Red Letter critiques. Both can be true at once:
cost-routing crossed a threshold with PR #224; faculty-validation
methodology needs to pause and get rigorous before more VALIDATED(NULL)
labels land.

## Files

- `/tmp/chump-together-v9.log` — full V9 trace
- `/tmp/chump-together-run-v9.sh` — launcher
- PR #224 — the shipped MCP servers
- PR #216 — step 3a overlay code (auto-merge armed)
- Predecessor: `docs/eval/COG-031-STEP2-V8-ROOFTOP-2026-04-19.md`

## Next

1. **Hold V10** until EVAL-060 + EVAL-061 are cleared.
2. After that: V10–V14 replication sweep, same backlog slice, measure real
   ship rate. Target: ≥50% per-subagent ship rate across 10 dispatches.
3. If replication holds: file COG-032 step-3b (commit-message-vs-diff
   verifier from V8 lesson) and COG-033 step-3c (system-prompt injection
   instead of user-message overlay, the stronger mechanism the reviewer
   anticipated).
4. Long-term: fine-tune a small open-source model on successful Chump traces
   (~$50) so the overlay isn't a prompt-engineering bandaid but a trained-in
   behavior. That's the "Chump runs on whatever you've got" endpoint.
