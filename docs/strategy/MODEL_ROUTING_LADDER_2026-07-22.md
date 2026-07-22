# Cost-tiered model routing — when M3 vs. when call up (EFFECTIVE-314)

Operator ask (2026-07-22): *"know when to use M3 vs. when to call up the
next/better thing that's best priced."*

## Empirical basis (live chumpd-eu, 2026-07-22)

- **M3 tool-calls fine.** A direct probe (concrete "fix `a - b` → `a + b`,
  code inline") got a flawless native `patch_file` call from MiniMax-M3.
  The fleet failures are **not** a tool-format problem.
- **M3 fails to converge.** Across ~15 real fleet cycles (thin-spec, `s`/`xs`
  gaps needing grep+read investigation) M3 reached `patch_file` **zero**
  times — it investigates, then can't synthesize the edit.
- **GLM-5.2 is a genuine rung up.** On the same gap pool it reached
  `patch_file` (INFRA-1961) where M3 never did — but still investigates
  enormously (22–55 grep calls) and mostly doesn't land. Better, not
  sufficient alone.
- **qwen3-coder-30b eliminated** — emits no tool_calls on OpenRouter
  (`finish_reason: stop`), despite being the cheapest coder-tuned option.

## Price ladder (OpenRouter, $/M in + out)

| Model | in | out | Role |
|---|---|---|---|
| deepseek-v4-flash | 0.10 | 0.20 | execute (concrete edits) |
| minimax-m3 | 0.30 | 1.20 | execute (concrete edits) |
| glm-5.2 | 0.78 | 2.44 | synthesize (investigate + edit) |
| claude-sonnet-4.5 | 3.00 | 15.00 | ceiling (research / hard / decompose) |

## The policy

**Escalate on failure (self-calibrating core — EFFECTIVE-314).**
`CHUMP_MODEL_ESCALATION_LADDER` is a cheapest-first comma list. Each prior
whole-gap failure (the EFFECTIVE-310 strike counter) bumps the next attempt
one rung. You never pay for a tier the task didn't need, and never
permanently stall.

**Full escalation stack** (cheapest → ceiling):

1. Open ladder rungs (e.g. `minimax/minimax-m3,z-ai/glm-5.2`) — EFFECTIVE-314.
2. `INFRA-267` — P0 gaps fall back to **Claude solving directly** on
   open-tier failure.
3. `EFFECTIVE-310` — at the strike threshold, **Claude decomposes** the gap
   into xs/s slices that re-enter the ladder cheap.

**Coordination:** set `CHUMP_DECOMPOSE_STRIKE_THRESHOLD >= ladder length`
so decompose doesn't cut the open ladder short.

**Route-by-shape (optimization, not yet built).** Concrete xs edits →
cheapest rung; thin-spec/investigate-heavy → start mid (GLM); research /
strategy / multi-file → Claude only. Signals already in the gap record:
effort, description length, AC concreteness, title keywords.

## Open question the data surfaced

The current backlog skews toward investigation-heavy `s` gaps that even the
mid tier struggles with. The throughput ceiling may be **gap-spec quality**
(thin descriptions, TODO acceptance-criteria) as much as model capability —
a concrete xs gap with a file pointer is what the cheap tier ships. Feeding
the cheap tier suitable work is a supply problem upstream of routing.
