# Chump in 5 Minutes

> A pitchable walkthrough for anyone who hasn't lived in this repo for a week.
> Read top-to-bottom; total time ~5 minutes. No powerpoint required — operator
> can present this by `cat`-ing sections aloud.
>
> Audience: external reviewers (Gemini, Marcus design-review), grant readers
> (NSF/DARPA/Mozilla), prospective collaborators, technical hires.
>
> Maintained as part of the canonical demo set under META-067 Track 3.

## 30-second elevator pitch

Chump is an **autonomous engineering fleet**: a small team of Anthropic-class
LLM agents that coordinate over a file + NATS substrate to ship real PRs to a
real codebase, all night, without human-in-the-loop. The substrate (gap
registry, lease atomicity, ambient event stream, A2A messaging) is the
differentiator — it's what lets multiple agents share state without stepping
on each other, hand off work, recover from failures, and stay honest about
what they're doing.

The goal isn't "AI writes code" (everyone has that). The goal is **fleet
mechanics that actually scale**: predictive collision detection,
skill-aware routing, calibrated bypass discipline, demo-grade throughput.

## The autopilot loop pattern

Today's working pattern is a 2-minute cron loop. Each tick, every active
curator does six steps:

1. **Glance** — `tail -30 .chump-locks/ambient.jsonl` + check active leases + read targeted inbox
2. **Babysit** — rebase + push DIRTY PRs; diagnose BLOCKED+FAILURE checks
3. **Check dispatches** — re-claim any 30-min-stale dispatched gap
4. **Ship** — claim a P1/P2 xs/s gap, write code, commit, push, auto-merge
5. **Dispatch peers** — broadcast 1-2 assignments to idle curators
6. **Report** — 3-line status to operator (SHIPPED / INFLIGHT / NEXT)

A "curator" is just an Opus-class session running this loop. Multiple curators
run in parallel, sharing the lease graph in `.chump-locks/` + the canonical
gap registry in `.chump/state.db`.

## Live lightning evidence

The honest measurement of what the fleet does is **prompt-to-PR-merged wall
clock** for the last 10 shipped PRs. Run this anytime:

```bash
bash scripts/dev/lightning-demo-timeline.sh
```

Example output (real, from 2026-05-23):

```
gap_id          PR  claim→open  open→merge  total_min  title
----------------------------------------------------------------------------
META-083     #2443       0.2        2.0        2.2  failure-class taxonomy
INFRA-1828   #2442       0.3       12.2       12.5  A2A RPC bash wrappers
INFRA-1866   #2440       0.2       24.3       24.5  flake-catalog audit
INFRA-1836   #2439       0.3        9.2        9.5  CHUMP_NO_BYPASS helper
INFRA-1874   #2437       0.3       20.1       20.4  Liaison Phase 2 slice β
CREDIBLE-068 #2435       0.3       11.2       11.4  merge-queue installer
INFRA-1834   #2434       0.4       15.1       15.5  --no-verify audit
INFRA-1871   #2433       0.0        9.8        9.9  pre-push timeout smoke
INFRA-1835   #2432       0.6        9.6       10.1  preflight tree-sha cache
META-074     #2431       0.4        1.8        2.2  strategy 6-week plan
----------------------------------------------------------------------------
Summary: 10 ships, total 118.2 min, median 10.1 min, p10 2.2, p90 20.4
```

**Read this as**: median ~10 min from operator-typed prompt (or gap claim) to
PR merged. Fastest is ~2 min (doc-only); slowest ~25 min (touches Rust →
full cargo workflow). The `claim→open` column is consistently <1 min — the
LLM/code-write phase is fast; **CI is the bottleneck**, not the agents.

## Screenshot list (for the slide deck operator builds out of this)

1. **PR queue screenshot** — `gh pr list --author @me --state open` showing
   8-12 PRs simultaneously in flight, all auto-merge armed, draining via CI
2. **Ambient stream tail** — `tail -30 .chump-locks/ambient.jsonl` with the
   FLEET-019 matrix output showing siblings + leases + alerts in real time
3. **Lightning timeline** — the table above (or a fresh run for the date of
   the pitch)

Optional 4th: the architecture diagram in `docs/process/A2A_FRONTIER.md`
showing the 6 layers (broadcast, RPC, capability, scratchpad, provenance,
multi-machine).

## The 4-pillar mission (one paragraph)

Every gap (Chump's unit of work) is tagged with which of four pillars it
serves: **Credible** (measurement / honest signal), **Effective** (user-
facing), **Resilient** (failure-class containment), **Zero-Waste** (no
wasted compute/IO/wall-clock). The fleet self-balances toward the
under-served pillar — when one starves, the curator-PM auto-files gaps
to refill. Today's run (counted at ~22:30 UTC) had 54 Effective / 22
Credible / 56 Resilient / 16 Zero-Waste open gaps pickable — see
`chump gap audit-priorities` for the live snapshot.

## What to take away

- **The agent-to-agent substrate matters more than the model.** Today's
  curators are stock Anthropic Opus + Sonnet sessions. The differentiator is
  the lease/inbox/ambient layer that lets them coordinate without stepping
  on each other. Swap in a local LLM tomorrow and the substrate still works.
- **Lightning prompt-to-PR-merged is the first demo.** It's the proof that
  the substrate scales, and it's directly observable via the timeline table.
- **The hard problems are forward-looking coordination** — predictive
  collision detection (META-075), skill-aware routing (META-077), cross-agent
  lesson propagation (META-079). All filed, none speculative.

## Call to action

- **Want to try it?** Clone the repo, run `bash scripts/setup/chump-fleet-bootstrap.sh`, then `chump --briefing <any-open-gap-id>` to see what an agent sees.
- **Want to review the architecture?** Start with [`AGENTS.md`](./AGENTS.md), then [`CLAUDE.md`](../CLAUDE.md), then [`docs/design/A2A_ROADMAP.md`](./design/A2A_ROADMAP.md).
- **Want to see today's actual numbers?** Run `bash scripts/dev/lightning-demo-timeline.sh` — refreshed in real time.
- **Want to dispatch agents?** Drop a gap with concrete AC into `chump gap reserve --domain INFRA --title "EFFECTIVE: ..."` — the picker will route it.
- **P&E Suite (Marcus M-D):** See [docs/strategy/CHUMP_PE_SUITE_DEMO_5MIN.md](strategy/CHUMP_PE_SUITE_DEMO_5MIN.md) for the 5-beat team-tier substrate demo — 14 curators deliberating on a real question in under 5 minutes (INFRA-2234).

---

*This doc is living. The pitch survives the codebase changing under it because
the only thing that's *literal* is the `lightning-demo-timeline.sh` output —
that always reflects today.*

*Maintained by curator-opus-ci-audit + the fleet. Last refresh: see
`git log -1 docs/DEMO_5MIN.md`.*
