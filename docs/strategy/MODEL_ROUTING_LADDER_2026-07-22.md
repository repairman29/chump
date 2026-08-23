---
doc_tag: decision-record
owner_gap: DOC-089
last_audited: 2026-08-08
---

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

---

## 2026-08-23: DeepSeek V4 primary, funded via OpenRouter (EFFECTIVE-445)

OpenRouter is now **funded** (paid credits, completions return `is_byok:false`
with a real `cost` field). The ladder is re-pointed so **DeepSeek V4 carries the
fleet across all rungs**, with Claude reserved as a rare last-resort ceiling.

### Wired ladder (`~/.chump/providers.env`, CJ + Pixel)

- `CHUMP_MODEL_ESCALATION_LADDER=deepseek/deepseek-v4-flash,deepseek/deepseek-v4-pro`
  — cross-gap quality escalation (strike 0 → flash, strike 1 → pro).
- `CHUMP_FREE_TIER_PROVIDERS=` free front-slots first
  (`nvidia/nemotron-3-super-120b-a12b:free` @ OpenRouter, `openai/gpt-oss-20b` @ Groq),
  then paid `deepseek/deepseek-v4-flash` and `deepseek/deepseek-v4-pro` @ OpenRouter
  as the on-429 failover. Free spells the paid rung; it never stalls.
- `CHUMP_COMPLETION_MAX_TOKENS=8192` — reasoning-headroom safeguard (see below).
- `CHUMP_DECOMPOSE_STRIKE_THRESHOLD=2` (== ladder length) so decompose does not
  cut the open ladder short.

### Live completion receipts (paid key, 2026-08-23, no key value printed)

| Model | HTTP | content on "17x3" | cost/call |
|---|---|---|---|
| `deepseek/deepseek-v4-flash` | 200 | `51` | ~$3.9e-6 |
| `deepseek/deepseek-v4-pro`   | 200 | `51` | ~$3.3e-5 (~9x flash) |

### Two wiring facts found the hard way

1. **Escalation-ladder entries must be BARE model IDs** (`deepseek/deepseek-v4-flash`),
   NOT `model@base:KEY`. `scripts/dispatch/worker.sh` (~L1568) borrows the
   `@base:KEY` suffix from the FIRST `CHUMP_FREE_TIER_PROVIDERS` entry when it pins
   an escalated model. A ladder that carries its own `@base:KEY` yields a malformed
   double-`@` spec that `parse_free_tier_providers()` mangles, causing transport
   failure. (The prior CJ value had `opencode.ai` `@base:KEY` suffixes on every
   rung — latent-broken.) Corollary: the FIRST free-tier provider must point at
   OpenRouter so the borrowed suffix routes the DeepSeek rungs correctly.
2. **DeepSeek V4 flash & pro are REASONING models.** They spend `reasoning_tokens`
   before emitting `content`; a low `max_tokens` cap returns empty `content`
   (max_tokens=30 gave `content=None`, the whole budget burned on reasoning). Give
   generous completion headroom — we set 8192.

### Free-tier RPM delay note

The free-tier execute path inserts `CHUMP_FREE_TIER_DELAY_MS` (default 5000ms)
between agent iterations to protect free quotas. Paid DeepSeek has high RPM and
does not need it; on a ~25-iteration investigate gap this alone adds ~2 minutes of
pure sleep. Lower it for paid rungs to materially improve throughput.

### Hypothesis under test: "DeepSeek V4 can do 100% of this"

Live-verified 2026-08-23 that DeepSeek routes and calls tools through the paid
OpenRouter key (per-request HTTP 200; `almanac_search` / `grep_repo` / `read_file` /
`patch_file` all fire). Landing behavior is **gap-shape dependent** — see the run
table in EFFECTIVE-445. Standing caveat: concrete xs edits are flash's sweet spot;
thin-spec investigate-heavy gaps make flash spin in investigation (many `grep_repo`
/ `read_file`, slow to synthesize the edit) exactly as M3 / GLM did, which is what
the flash → pro strike escalation exists to catch.

### Real fleet-gap runs on the wired paid ladder (2026-08-23, CJ)

Each run: `chump claim` + `chump --execute-gap` in the linked worktree, provider
pinned to a single DeepSeek rung so the model under test is unambiguous. Every
LLM call returned HTTP 200 from `openrouter … deepseek-v4-*` — routing is proven.
Landing is **gap-shape dependent**:

| Gap | Shape | Rung | Tool loop | Result |
|---|---|---|---|---|
| CREDIBLE-111 | xs, **concrete**, single-file doc edit (add case study to a named .md) | flash | almanac + 1 `grep` + 6 `read` + **2 `str_replace`** | **LANDED** — real diff (+45), fleet PR #4180, auto-merge armed |
| CREDIBLE-120 | xs, thin-spec, investigate-heavy (fleet-brief exit code, no file pointer) | flash | 30 iters, ~25 `grep_repo` + ~12 `read_file`, **0 edits** | empty diff — no land |
| CREDIBLE-110 | s, thin-spec, investigate (CLI unknown-subcommand) | pro | 4 investigate calls, then returned final text, **0 edits** | empty diff — no land |

**The dividing line is gap-spec concreteness, not raw model power.** Given a
concrete gap with a named target file, DeepSeek-v4-flash converges and edits with
`str_replace` (the very tool weak models used to dodge — the old M1 wall) and ships
a real PR. Given a thin-spec investigate gap with no file pointer, flash *spins*
(keeps grepping, never synthesizes) and pro *gives up early* — the same
"investigate, never synthesize" failure M3 / GLM showed in the 2026-07-22 study.
The 2026-07-22 doc already named the cause: "a concrete xs gap with a file pointer
is what the cheap tier ships." Feeding the cheap tier suitable work is a supply
problem upstream of routing.

Compounding harness factor: the free-tier **5000ms inter-iteration delay** turns a
30-iteration investigation into ~2.5 min of pure sleep on top of decode — it makes
a spin look catastrophic and burns the wall-clock timeout. Paid DeepSeek has high
RPM and does not need this throttle; lower `CHUMP_FREE_TIER_DELAY_MS` for paid rungs.

**Cost:** concrete land ~$0.01–0.02; a 30-iter flash spin ~$0.05; pro give-up
~$0.01. Lifetime key usage $10.23 (`is_free_tier:false`); the whole test burned
pennies. No drain risk.

**Verdict on "DeepSeek V4 does 100%":** No — not as a blanket claim. It lands
concrete, well-specified gaps solo (and cheaply), but does **not** land thin-spec
investigate-heavy gaps solo. Keep the flash → pro strike escalation and the Claude
decompose/ceiling — they exist for exactly the class DeepSeek misses. The higher-
leverage fix is upstream: **concrete gap specs with file pointers** convert far more
of the backlog into DeepSeek-shippable work than any model swap.
