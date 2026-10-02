# Rulebook archive — pre-ZERO-WASTE-125 full text

ZERO-WASTE-125 cut `CLAUDE.md` from 700 lines and `AGENTS.md` from 1129
lines down to their enforced budgets (150 / 300). This archive holds the
full prior prose for anything that was condensed rather than deleted
outright, so the detail isn't lost — only moved out of the context every
agent pays for on every session.

Most of what was in `CLAUDE.md` / `AGENTS.md` before this cut already had
(or now has) a dedicated on-demand doc — those sections were deleted from
the root files, not archived here, because the canonical version already
exists elsewhere (see the pointer tables in `CLAUDE.md` / `AGENTS.md`
"On-demand docs" / "Where to find docs" sections).

This archive covers the handful of sections that had **no** pre-existing
dedicated doc: narrative/historical material whose value is in the story,
not a rule an agent needs loaded every session.

## From AGENTS.md: "Filing meta-patterns — when individual filings aren't enough"

Reactive filing (file the symptom you just observed) is necessary but not
sufficient. Sessions in flow miss recurring patterns because each incident
looks unique in the moment.

**1. Periodic RCA pass.** At cycle end (and at any natural pause), run a
5-minute scan of the gaps you filed this session: which share root causes?
File a META-* gap covering the class. The 2026-05-02 ghost-elimination
session is the cautionary example: 14 individual gaps filed, two recurring
patterns (per-file YAML mid-flight collisions; agents conflating local
working tree with origin/main state) only got filed because the operator
asked.

**2. Verify-against-origin/main before filing RCA gaps.** When a gap
description claims "X reverted my change / origin has unexpected state,"
verify with `git fetch origin main && git show origin/main:<path>` BEFORE
filing. INFRA-238 was a 100% misdiagnosis (~30 min wasted) caused by
reading system-reminder file content as origin/main state. This is now
codified as "Diagnosing divergence" in `AGENTS.md`.

**3. Pattern-counter automation.** `scripts/coord/recurring-gap-pattern-detector.sh`
(INFRA-249) runs against recently-filed gap titles, surfaces clusters with
N≥3 gaps in 7 days sharing significant keywords, emits ALERT lines to
`ambient.jsonl`.

**4. Runtime verification before missing-claim.** Before filing a gap
claiming a feature is missing, run `scripts/dev/verify-existence.sh
<ID-or-symbol>` (INFRA-1589) — tri-state `{confirmed_shipped |
confirmed_absent | ambiguous}`. INFRA-1575 (2026-05-16) is the cautionary
precedent: an agent filed a P1 gap claiming a 10-gap A2A implementation
chain was missing from the registry; all ten had in fact shipped. The
agent stopped at `chump gap show: not found` and never checked git history
or the runtime surface.

## From AGENTS.md: "Naming conventions" migration detail

The project owns the namespace, not the tool: branches, worktree paths,
lease files, ambient events, and bot identities use the `chump-` / `chump/`
/ `.chump/` prefix regardless of which agent is the actor.

| Artifact | Canonical | Acceptable (legacy) |
|---|---|---|
| Feature branch | `chump/<short-codename>` | `claude/<…>`, `cursor/<…>`, etc. |
| Linked worktree | `.chump/worktrees/<name>/` | `.claude/worktrees/<…>` |
| Bot commit identity | `<role>@chump.bot` | (already canonical) |

Existing `claude/*` branches and `.claude/worktrees/` trees stay as
history — no rename. New branches and worktrees use `chump/<codename>` and
`.chump/worktrees/<name>` going forward. `bot-merge.sh` and `chump gap`
commands accept either prefix during the transition.

## From AGENTS.md: "Reach asymmetry — Claude sessions vs bash daemons" (INFRA-2263)

Not every fleet agent reads the ambient wire the same way:

| Consumer class | How it sees broadcasts | Cadence |
|---|---|---|
| Claude Code sessions | SessionStart hook injects ambient.jsonl tail digest | once per session start, then PreToolUse refreshes |
| Bash curator-loop daemons (decompose-loop / handoff-loop / ci-audit-loop / md-links-loop) | Do NOT read ambient, do NOT subscribe to NATS — write-only by construction | never |
| `chump-coord watch` | Live NATS subscription | real-time |

Implication: broadcasting a proposal that needs a bash-curator-lane
response actually reaches the *Claude orchestrators* of those lanes, not
the loops themselves, unless the loop explicitly reads ambient on its tick.

## From AGENTS.md: "Stacked PRs" (INFRA-061 / M3)

When two related gaps touch the same files, ship them as a stack: the
second PR uses the first PR's branch as its base, so when the first PR
lands, the merge queue auto-rebases the stacked PR onto new main.

```bash
scripts/coord/bot-merge.sh --gap GAP-A --auto-merge           # PR #100, base=main
scripts/coord/bot-merge.sh --gap GAP-B --stack-on GAP-A --auto-merge  # PR #101, base=branch-of-#100
```

`bot-merge.sh` resolves `--stack-on <PREV-GAP>` via `gh pr list`; falls
back to `base=main` if the prev gap's PR already landed. Reserve stacks
for logically distinct changes — a mechanical codemod across many files
still ships as one atomic PR.
