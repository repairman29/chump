# Agent Memory Tiers — Tier 3 Leverage and the Migration Discipline

> **Status:** Filed 2026-05-03 (DOC-016) after the META-025 measurement
> contract closed at 75% self-ship rate (vs 25% baseline) — empirical
> validation that Tier 3 has more behavioral leverage than Tier 2.
>
> **Falsifying claim:** if next session's post-META-028 measurement run
> shows self-ship rate regresses below 70%, the Tier 3 leverage thesis
> is wrong and this doc retracts.

## TL;DR

Chump's project memory has three distinct tiers, each with different
load semantics and different agent-quality leverage:

| Tier | What | How agents see it | Leverage |
|---|---|---|---|
| **1 — code** | Canonical, executable | Run as a subprocess (`chump gap …`, `bot-merge.sh`) | High; deterministic |
| **2 — docs** | Canonical, descriptive | Agent reads the file IF it knows to load it AND has context budget | Variable; selection-dependent |
| **3 — runtime memory** | Canonical, prescriptive | Welded into the agent's system prompt before it makes any decision | High; involuntary |

Today's META-025 measurement (2026-05-03) is the empirical validation:

- **25%** historical baseline self-ship rate (`chump_improvement_targets`
  dispatch telemetry, mostly `chump-local` backend pre-INFRA-332).
- **75%** measured self-ship rate (4 of 4 measurable subagents) after
  Tier 3 shipping-epilogue (INFRA-332 / `docs/process/SUBAGENT_DISPATCH.md`)
  was injected into every Agent-tool prompt.
- **Same model** (claude-opus-4-7), **same task class** (small INFRA/META
  gaps with well-defined acceptance criteria), **same repo state**.
- The **only changed variable** was the briefing template structure.

A 3× behavioral improvement from a 30-line doc, on the same model. Most
"agent quality" discourse is about model capability; today's evidence
says briefing structure has more lever than swapping models for this
class of work.

---

## Tier 1 — Code

The canonical executable infrastructure. Examples in Chump:

- `scripts/coord/bot-merge.sh` — the ship pipeline
- `chump gap` subcommands (Rust binary)
- `scripts/git-hooks/pre-commit` — commit-time guards
- `scripts/dev/chump-binary-unwedge.sh` — INFRA-275 binary heal

Tier 1 is the highest-leverage tier per unit of effort because it's
**deterministic**: an agent invokes the script, the script runs the
same way every time, the outcome is recorded.

But Tier 1 alone doesn't tell agents WHEN or WHY to invoke it.

## Tier 2 — Docs

The canonical descriptive context. Examples:

- `CLAUDE.md` — session rules + commit guards table + fleet launcher
- `AGENTS.md` — cross-tool entry point
- `docs/process/RESEARCH_INTEGRITY.md` — methodology gold-standard
- `docs/process/AGENT_COORDINATION.md` — coordination semantics
- `docs/strategy/NORTH_STAR.md` — strategic frame

Tier 2 has two properties that limit its agent-quality leverage:

1. **Optional load.** An agent only reads it if (a) the agent knows the
   doc exists, (b) the agent decides it's relevant to the current task,
   (c) context budget allows. Any of those failing → the doc isn't read.

2. **No execution semantics.** Even when read, Tier 2 is descriptive.
   "When chump --version hangs, run scripts/dev/chump-binary-unwedge.sh" is a
   *suggestion* in Tier 2 form. The agent has to remember it AND choose
   to apply it AND not have it crowded out by the next 50 things they
   read.

Tier 2 works for descriptive content (history, architecture, the "why").
It does not reliably govern agent behavior under stress.

## Tier 3 — Runtime-injected agent memory

The canonical *prescriptive* content, programmatically prepended to an
agent's system prompt before the agent makes any decision. Examples in
Chump:

- **The shipping epilogue** (INFRA-332) — pasted verbatim into every
  Agent-tool prompt. Documents bot-merge.sh canonical path, chump-doctor
  heal, INFRA-028 manual recovery, the `do NOT silently fall back to
  YAML writes` discipline.
- **The lessons pool** (INFRA-330 + COG-024 / COG-032 path) — 15
  actionable directives in `chump_improvement_targets`, surfaced via
  `CHUMP_LESSONS_AT_SPAWN_N=N` + the `format_lessons_block()` helper.
- **`chump --briefing <GAP-ID>`** (MEM-007) — per-gap context bundle
  injected as an explicit retrieval before agent invocation.
- **`src/system_prompt.rs::chump_system_prompt()`** — the assembled
  prompt itself, including hard-rules + thinking-XML primacy + soul +
  intent-action-compact + brain-soul + project-soul + agent-team-block +
  tool-examples-block.
- **The default substrate config** — model selection, max iterations,
  temperature defaults baked into `agent_factory.rs`.

Tier 3 is **not optional**. The agent doesn't have to remember to load
it. It's there before the agent makes its first decision.

## Why Tier 3 has more leverage

The empirical case (META-025): 4 subagents, 4 different tasks, same model,
same docs. The single subagent in the original 4-spawn run that
self-shipped was the one whose briefing included explicit fall-back-to-
manual-recovery instructions in Tier 3 form. The other 3 had
identical *Tier 2* documentation of the same recovery path (in CLAUDE.md
+ docs/process/) but did not act on it under stress.

After making the recovery instructions Tier 3 (verbatim copy in every
subagent prompt via `docs/process/SUBAGENT_DISPATCH.md`), the rate
inverted: 3 of 4 measurable subagents self-shipped, with 2 of those
explicitly invoking the manual-recovery path the epilogue prescribed.

The mechanism, stated plainly: **agents under stress consult the prompt
they were spawned with, not the docs they could go read.** Tier 2 is
high-quality reference material; Tier 3 is operational scaffolding.

## Tier 2 → Tier 3 migration discipline

Most prescriptive content currently in Tier 2 has more leverage in
Tier 3 form. The discipline is to migrate it deliberately, not let it
accumulate in CLAUDE.md unread.

### Migration candidates (move to Tier 3)

- "MANDATORY: run before anything else" pre-flight commands
- Hard rules ("never push directly to main", "never hand-edit
  docs/gaps/<ID>.yaml")
- Recovery patterns (chump-doctor on hang; INFRA-028 manual on bot-merge
  timeout; reset-soft + cherry-pick on stacked-PR rebase)
- Bypass envs an agent might need under stress (`CHUMP_GAP_CHECK=0` for
  cleanup pushes; `CHUMP_RAW_YAML_EDIT=1` + reason trailer for filing PRs)
- Methodology constraints that gate behavior (falsifying conditions on
  acceptance criteria; cross-judge audit before evaluation closure)

### Stay in Tier 2 (descriptive, agent reads on demand)

- History ("PR #52 historical context — 11 commits lost on 2026-04-18")
- Architecture explanation ("the SQLite store became canonical in
  INFRA-059 because the YAML race produced 4 corruption incidents")
- Strategy framing ("offline mission — the kid without GH access")
- Walk-through tutorials and onboarding context

### Migration mechanism

[META-028](../gaps/META-028.yaml) — per-spawn defaults — is the
canonical mechanism: a project-owned briefing-prefix file that every
Agent-tool spawn loads + concatenates BEFORE the operator's task-specific
prompt. This is how Tier 3 content stays consistent across all spawns
without relying on operator paste hygiene.

[META-031](../gaps/META-031.yaml) — CLAUDE.md size + structure governance
— is the prune-side discipline: as content migrates from CLAUDE.md (Tier
2) to Tier 3, CLAUDE.md should shrink. Smoke test in the gap: fail
build when CLAUDE.md > 1500 lines, suggesting prune candidates.

[INFRA-396](../gaps/INFRA-396.yaml) — cascading silent-failure smokes —
is the verification-side discipline: every load-bearing Tier 3 path gets
a smoke test that asserts "this still produces non-trivial output."
Tier 3 paths can break silently (chump --briefing was broken
post-INFRA-188; the lessons-injection feature was effectively disabled
for weeks before today). Smokes catch that.

## Scaling doctrine — what to keep tightening as we add agents/machines/operators/substrates

The Tier 3 frame produces a clear scaling story for each axis:

### N agents (parallelism)

**Tier 3 is the multiplier.** Every new spawn inherits the discipline
automatically; no operator paste required. META-028 (per-spawn defaults)
and META-030 (orchestrator-subagent backchannel) are the load-bearing
gaps.

### N machines (cross-host fleet)

Tier 3 content lives in version control + .env on each host; it
replicates via `git pull` + `scripts/setup/install-all.sh`. The
load-bearing gaps for machine-N are:

- [INFRA-395](../gaps/INFRA-395.yaml) — substrate-pressure pre-flight
- [INFRA-400](../gaps/INFRA-400.yaml) — `/private/tmp` daily cleanup
- [INFRA-398](../gaps/INFRA-398.yaml) — `install-all.sh` for new dogfood
  machines
- [INFRA-399](../gaps/INFRA-399.yaml) — subagent transcript archival

### N operators (multi-human teams)

Without Tier 3 defaults, every new operator has to memorize the
shipping epilogue, the chump-doctor heal pattern, the
Agent-vs-SendMessage rule. With Tier 3 defaults, every operator's
spawned agents inherit the discipline automatically. This is META-028's
core value at human-scale.

### N projects (Chump methodology applied beyond the chump repo)

The doctrine itself travels via **this doc** + the operational gaps
(META-028 for the mechanism, INFRA-396 for the verification). Projects
adopting the methodology get measurable agent-quality improvement
WITHOUT needing the chump-specific Tier 1 / Tier 2 tooling — they just
need their own Tier 3 epilogue and lessons pool.

### N substrates (model classes — opus / sonnet / haiku / qwen3 / etc.)

Tier 3 is **substrate-portable**. The 75% measured rate was on
claude-opus-4-7; the same epilogue should work on smaller substrates
because it's about constraining behavior, not augmenting capability.
[RESEARCH-032](../gaps/RESEARCH-032.yaml) measures whether qwen3:14b
can compose Chump's full agent loop; if it can, the same Tier 3
discipline applies. If it can't, the failure mode is substrate ceiling,
not Tier 3 design.

The cascade visibility ([INFRA-352](../gaps/INFRA-352.yaml)) and
backend telemetry split ([INFRA-336](../gaps/INFRA-336.yaml)) become
load-bearing because Tier 3 content needs to reach the agent regardless
of which substrate the call lands on.

### N invocation paths (Agent tool / claude -p / chump --execute-gap / web UI / MCP)

Each invocation path has its own way of assembling the system prompt.
Tier 3 content needs a canonical source-of-truth that all paths
reference, not a per-path copy. `src/system_prompt.rs` is the existing
canonical assembler for chump-internal calls; extending the same
pattern to Agent-tool spawns (META-028) closes the gap.

---

## What we're not claiming

- **Tier 3 is not magic.** It depends on the underlying model's
  instruction-following capacity. A model that ignores its system prompt
  isn't fixed by a better system prompt.
- **Tier 3 doesn't replace methodology gates.** RESEARCH_INTEGRITY's
  cross-judge audit, prereg, falsifying-condition discipline still
  apply. Tier 3 is the operational scaffolding; methodology is the
  research-quality gate.
- **Re-measurement is still required.** Any Tier 3 change needs
  measurement to close the contract. Today's META-025 closure was
  predicated on 75% measured, not 75% claimed.
- **Tier 3 can rot.** Stale directives accumulate; periodic review (the
  Cold Water audit, cycle review) needs to prune Tier 3 the same way
  Tier 2 needs prune.

## Authoring discipline for new Tier 3 content

Each Tier 3 directive should:

1. **Be small.** A few sentences, not a wall of text. Agents under stress
   consult, they don't read.
2. **Be falsifiable.** Each directive should pin the observable failure
   mode it prevents. ("If you fall back to YAML writes when chump
   reserve hangs, concurrent siblings produce silent collisions —
   INFRA-301.")
3. **Be action-oriented.** "Run X" / "Don't do Y" / "If A, do B" — not
   "agents should consider Z."
4. **Cite the source incident.** Every Tier 3 lesson is paid for in
   wasted PR-recovery time. The citation is what justifies the prompt
   bytes.

The seed at `scripts/ab-harness/fixtures/lessons-seed-infra-v1.json`
exemplifies this — every directive points to a real session-history
failure mode + the gap that filed it.

## Followups

- [META-028](../gaps/META-028.yaml) — per-spawn briefing-prefix defaults
  (the migration mechanism)
- [META-031](../gaps/META-031.yaml) — CLAUDE.md size governance (the
  prune side)
- [INFRA-396](../gaps/INFRA-396.yaml) — cascading silent-failure smokes
  (the verification side)
- [META-029](../gaps/META-029.yaml) — re-measurement as default closure
  (the validation side)

When all four ship, Tier 3 has a complete authoring → migration →
verification → re-measurement loop. Until then, the migration is
manual + the discipline rides on Cold Water audit attention.

## See also

- [`docs/process/SUBAGENT_DISPATCH.md`](../process/SUBAGENT_DISPATCH.md)
  — the canonical Tier 3 example (shipping epilogue)
- [`docs/process/RESEARCH_INTEGRITY.md`](../process/RESEARCH_INTEGRITY.md)
  — methodology gates this doctrine respects
- [`scripts/ab-harness/fixtures/lessons-seed-infra-v1.json`](../../scripts/ab-harness/fixtures/lessons-seed-infra-v1.json)
  — Tier 3 lessons-pool seed
- [`src/system_prompt.rs`](../../src/system_prompt.rs)
  — the canonical Tier 3 assembler for chump-internal agent calls
