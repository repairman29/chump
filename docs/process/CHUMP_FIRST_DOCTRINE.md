---
doc_tag: doctrine
owner_gap: META-046
last_audited: 2026-05-13
companion_docs:
  - docs/process/HARNESS_CONTRACT.md
---

> **See also:** [`HARNESS_CONTRACT.md`](HARNESS_CONTRACT.md) (INFRA-1044) — the concrete technical surfaces a harness implements. This doc is the *why*; that doc is the *what*.


# Chump-first doctrine

This doc declares the design constraint that should drive every chump PR:
**chump is a universal coordination platform; Claude is one backend among
many.** When a PR adds Claude-specific code, it must demonstrate why no
abstraction works — otherwise it's runtime lock-in dressed as a feature.

## Why this doc exists

A 2026-05-11 audit (after the operator asked "are we drifting toward
Claude-specific work?") found:

- **The valuable IP is universal**: state.db, gap registry, PR hygiene
  gates, canonical-state-contract, atomic ID allocator, ambient stream.
  Anyone could use it.
- **The runtime is Claude-locked**: `src/dispatch.rs` hard-codes
  `claude -p` as the worker; `src/auth.rs` handles only Anthropic
  credentials; `scripts/coord/*` has 1499 `claude` references baking
  the harness in.

The mission is offline solo devs on local LLMs ([per memory](
project_offline_local_llm_mission.md)). Claude-locked dispatch means
chump can't actually run that mission for a non-Anthropic operator.

## The contract

1. **The state layer is canonical and universal.** state.db, per-gap
   YAMLs, canonical-state-contract, ambient.jsonl, lease files. No
   provider name appears here without justification.
2. **The runtime layer is pluggable.** Workers, auth, attribution — each
   has a trait/abstraction and ships with at least 2 implementations.
   Adding a third backend should be a small PR, not a rewrite.
3. **Backward compatibility for one cycle.** When renaming a surface
   (e.g., `.claude/worktrees` → `.chump/worktrees`), keep the old path
   working for one cycle with a deprecation warning.
4. **Default to "universal" in new code.** When in doubt, write the
   non-Claude path first; add Claude support as one variant.
5. **PRs that hard-code Claude assumptions must justify them.** A
   `Co-Authored-By: Claude` trailer is fine; a `Command::new("claude")`
   in a generic-sounding function is not.

## What this isn't

- **Not "remove Claude."** Claude-the-backend is the operator's current
  best-known. The fleet runs on Sonnet today. The doctrine is about
  *how* Claude is wired in, not *whether*.
- **Not "ship a Llama clone of everything."** Don't write speculative
  abstractions for backends nobody's using. Wait until the second
  backend has a real operator.
- **Not anti-Anthropic.** Anthropic API access is a great default. The
  doctrine is that the default doesn't dictate the architecture.

## Universalization gaps

The audit produced six gaps that, together, complete the universalization:

| Gap | Surface | Effort |
|---|---|---|
| [EFFECTIVE-017](../gaps/EFFECTIVE-017.yaml) | `WorkBackend` trait + plug-in worker variants | m |
| [EFFECTIVE-018](../gaps/EFFECTIVE-018.yaml) | Pluggable auth manager (generic credential store) | s |
| [EFFECTIVE-019](../gaps/EFFECTIVE-019.yaml) | `scripts/coord/*` sweep (1499 Claude refs → universal) | m |
| [EFFECTIVE-020](../gaps/EFFECTIVE-020.yaml) | `.claude/worktrees` → `.chump/worktrees`; CLAUDE.md → AGENTS.md | s |
| [CREDIBLE-045](../gaps/CREDIBLE-045.yaml) | Generic agent-attribution in bot-merge + commit trailers | xs |
| [CREDIBLE-046](../gaps/CREDIBLE-046.yaml) | "chump without Anthropic" CI gate | m |

Once all six land, a solo dev can boot chump on local Ollama with zero
Anthropic credentials and complete a full gap-claim-ship cycle. The
doctrine becomes load-bearing: the CI gate (CREDIBLE-046) makes
backsliding cost a PR.

## Review checklist (for every PR)

Reviewers should ask:

- Does this PR add a new `claude`/`anthropic` reference? Is it in the
  state layer (forbidden) or the runtime layer (allowed if justified)?
- If it's a worker-spawn or auth path, does it go through the
  abstractions in EFFECTIVE-017/018?
- If it's a coordination script, does it use `CHUMP_WORKER_CMD` instead
  of hard-coding `claude`?
- Does the CI gate ([CREDIBLE-046](../gaps/CREDIBLE-046.yaml), once
  shipped) pass?

A PR that violates the doctrine should not block on this doc alone —
file a follow-up gap to abstract the offending code rather than rejecting
the substantive change. The doctrine constrains the slope, not the
single decision.
