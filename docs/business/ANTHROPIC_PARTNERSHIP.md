# Anthropic Partnership — Outreach Brief

> **STUB (2026-07-29) — draft retired pending ChumpOS-aligned rewrite.**
> Filed as INFRA-1501, tracked in `chump-proprietary/OPERATOR_ACTIONS.md`.
> The full prior draft (contact path, 3-paragraph pitch, 4 documented SDK
> edge cases, decision-rule timeline, draft DM/email copy) is preserved in
> git history (see `git log -- docs/business/ANTHROPIC_PARTNERSHIP.md`) —
> nothing was deleted, it's just not the live draft anymore.
>
> **Why stubbed:** the prior pitch was built on "Claude Code is Chump's
> only/100% harness," which the 2026-07-27 ChumpOS harness-agnostic
> reframing made false (OpenCode is now the default gateway for bulk work;
> Claude Code is the hard-ship fallback). Patching the specific false lines
> wasn't enough — the whole pitch angle needs to be re-derived from current
> positioning, not line-edited.
>
> **Before re-drafting this, read:** [docs/PITCH.md](../PITCH.md) and
> [docs/ROADMAP.md](../ROADMAP.md) ("The ChumpOS arc") for current
> positioning, and re-pull the actual current harness-mix split from live
> fleet metrics rather than assuming a number. The underlying facts worth
> keeping (documented SDK edge cases: pty exhaustion, OAUTH precedence,
> worktree gitdir corruption, 30-min ship-wall) are still real and still
> worth a version of this pitch — just not this draft, as written.
>
> Tracking note (legal-sensitive): the live operator decision on whether/when
> to send anything to Anthropic stays in `chump-proprietary/OPERATOR_ACTIONS.md`,
> not here.

---

## Kept for reference: the underlying facts (still true, need a new pitch built around them)

- 4 documented production-scale Agent-SDK edge cases with reproducers: pty
  exhaustion (~60–94 ptys/dispatch, `docs/process/SUBAGENT_DISPATCH.md`),
  OAUTH-precedence false-positive "auth dead" (RESILIENT-086,
  `scripts/coord/auth-status.sh`), macOS worktree gitdir corruption
  (INFRA-779, now auto-repaired by `chump claim`), and the 30-min
  `step=init` ship-wall for interactive-session sub-agent dispatch.
- `AGENTS.md` follows the Linux Foundation AGENTS.md cross-tool spec —
  still a real, still-current reference-implementation angle regardless of
  harness mix.
- Contact path (Mike Krieger primary, developers@anthropic.com secondary,
  HN/X tertiary) and the 0/3/30/60/90-day decision-rule cadence are
  reusable structure — only the pitch content built on top needs redoing.
- Launch dependency: INFRA-1501, cross-linked from `docs/ROADMAP.md` Phase 4.
