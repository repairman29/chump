# COTG Execution Matrix — verified status + graft sources (DOC-075)

> **What this is.** `COTG_READINESS_BACKLOG.md` is the canonical design; `CHUMP_FRONT_DOOR.md`
> is the entry architecture; `CHUMPBENCH.md` is the proving ground. Each proposes a partial
> sequence. This doc reconciles all three into **one execution order**, with every gap's
> status **verified against current main** (not assumed from a gap ID existing), and every
> graft source cited with a receipt. Built for the fleet to pick from directly — read
> top to bottom, pick the next unblocked row.
>
> **Filed:** 2026-07-29, operator-directed research pass (harvester arsenal scan + deep repo
> re-scan + OSS prior-art scan, 3 parallel agents). Supersedes each source doc's own §6 for
> sequencing purposes; those docs remain the AC source of truth per gap.

## How to read this

- **Status** is verified, not assumed: `DONE` (shipped + wired + live-called), `PARTIAL`
  (exists but not fully wired — see note), `NOT-FOUND` (genuine build), `GRAFT` (exists
  elsewhere — arsenal repo or OSS pattern — needs porting, not inventing).
- **Serial?** — `SAME-FILE` rows touch `src/improve.rs`/`src/execute_gap.rs` and **cannot
  be fleet-parallelized against each other** (same lesson as INFRA-3287's main.rs
  decomposition: one PR at a time on a hot file, or constant collisions). Everything else
  marked `PARALLEL` can run as concurrent fleet workers.
- **Model class** follows COTG-1.6's own rule once it ships: mechanical wiring → cheap tier;
  genuine construction / judgment-heavy → strong tier. Stated per row as the interim manual
  call until 1.6 lands and does this automatically.

## Phase 0 — Gate (cheap, first, unblocks everything downstream)

| Order | Gap | What | Status | Serial? | Model class |
|---|---|---|---|---|---|
| 0.1 | COTG-S.4 | wire the organs into dedup (structural completeness, not keyword match) | NOT-FOUND, cheap wiring per original doc | PARALLEL | cheap |
| 0.2 | COTG-S.1 | sourcing resolver (repo→arsenal→world before building) | NOT-FOUND | PARALLEL | strong (judgment: DONE-HERE vs BUILD calls) |
| 0.3 | COTG-3.3 | parse `Chump-Agent` trailer into the scoreboard | **likely already DONE** — live `mission-scoreboard.sh` output already inspects trailer presence ("0 carry the Chump-Agent trailer"). **Verify before picking; may just need closing.** | PARALLEL | cheap |
| 0.4 | — | catalog `almanac` (`~/Projects/almanac`) in `docs/arsenal/GLOBAL_ARSENAL.json` | NOT-FOUND — harvester's own catalog is 2 months stale, missing a repo it already depends on | PARALLEL | cheap (`scripts/arsenal/build.py` re-run + manual entry) |

## Phase 1 — Reliability floor on IMPROVE (the one rail Front Door says to prove first)

**Update (verified 2026-07-30, mid-research):** the fleet shipped 6 of these gaps while
this matrix was being built — real merged PRs, checked as actual ancestors of current
`main`, not just trusted from gap-status labels:

| Gap | Registry status | PR | Verified merged into current main? |
|---|---|---|---|
| INFRA-3483 (COTG-1.1, typed FSM) | shipped | — | not independently re-checked below |
| INFRA-3484 (COTG-1.2, deterministic ceremony) | shipped | — | not independently re-checked below |
| INFRA-3485 (COTG-1.3, edit-verify gate) | shipped | #3396 (INFRA-3516) | ✅ verified 2026-08-04 — the hole IS closed (see below) |
| INFRA-3486 (COTG-1.4, durable/resumable exec) | done | #3378 | ✅ merge SHA confirmed ancestor of main |
| INFRA-3488 (COTG-1.6, task-fit model selection) | done | #3374 | ✅ merge SHA confirmed ancestor of main |
| INFRA-3489 (COTG-2.1, intervention watchdog) | done | #3384 | ✅ merge SHA confirmed ancestor of main |
| INFRA-3490 (COTG-2.2, gate self-heal) | done | #3381 | ✅ merge SHA confirmed ancestor of main |

**✅ Discrepancy RESOLVED — re-verified against current main 2026-08-04 (DOC-078).** The
earlier warning was written against **pre-INFRA-3516** code; the hole it described is
**closed**, and the line refs above (`improve.rs:1783`/`:1861`) no longer exist on main.
INFRA-3516 (commit `b344ae92`, PR #3396) introduced ONE shared staging+commit ceremony,
`guarded_stage_and_commit()` (`src/improve.rs:1085`), which calls `verify_staged_edit()`
(`src/improve.rs:1013`) at `:1109` — after `git add -A` + junk-drop, before commit. Every
real commit path now funnels through it: `deterministic_ship` → `:1151`; `fix_pr` (the CI
remediation path) → `:2116`; `remediate_held` (`:2141`) has **no independent commit
branch** — its only mutating arm is `Remediation::AgentFix => fix_pr(...)` at `:2177`, so
it is covered transitively. So `fix_pr`/`remediate_held` **are** gated. No Phase-1 work
remains here; treat INFRA-3485/COTG-1.3 as genuinely done. (Lesson kept: the original
warning was right to distrust the label and verify against source — that discipline is
what caught this was already fixed, not still broken.)

**Remaining Phase 1 items (verify before assuming needed — labels have already proven
unreliable once above):**

| Order | Gap | What | Status | Model class |
|---|---|---|---|---|
| ~~1.1~~ | INFRA-3485 / COTG-1.3 | route `fix_pr`/`remediate_held` through `verify_staged_edit()` | ✅ **DONE** (INFRA-3516 #3396) — both route through `guarded_stage_and_commit` → `verify_staged_edit` (verified 2026-08-04, DOC-078). No work remaining. | — |
| 1.2 | — | extend checkpoint/resume (`src/improve.rs:1168-1199`) to `src/execute_gap.rs` — zero refs there as of this check | verify whether INFRA-3486's "done" PR covered this too, since it was scoped narrow originally | medium |

## Phase 2 — Make the loop measurable (pulls COTG-3.1 + 5.1 ahead of finishing Epic 2 — Front Door's override, and it's correct: don't build self-heal around an unmeasurable loop)

| Order | Gap | What | Status | Serial? | Model class |
|---|---|---|---|---|---|
| 2.1 | COTG-3.1 | wire `src/browser.rs`/`browser_tool.rs` (`navigate`/`screenshot`, already live) against a DoD-assertion gate | DONE-HERE (primitive) + NOT-FOUND (the gate composition) — **much smaller than "build browser automation"** | PARALLEL | strong (judgment: pass/fail against NL criterion) |
| 2.2 | COTG-5.1 | stage+promote split (revised AC, this session) — graft Vercel preview/promote (hosted) or Dokku/e2b pattern (self-hosted) | GRAFT — 6+ of Jeff's own repos already do the hosted half | PARALLEL (after 2.1's gate exists) | strong (new subsystem) |
| 2.3 | — | **run `chump bench run --track e2e/chumpbench/rescue-beast-ci.yaml --apply`** — get the first real human-touches-per-lap number | tool DONE (merged), **never executed — zero `chumpbench_lap` events ever** | — | n/a, just run it |

## Phase 3 — Close the zero-touch loop (Epic 2 remainder), now justified because it's measurable

| Order | Gap | What | Status | Serial? | Model class |
|---|---|---|---|---|---|
| 3.1 | INFRA-3489 / COTG-2.1 | wire `src/intervention_watchdog.rs` into a live coordination loop | **registry says done (#3384, verified merged) — spot-check it's actually invoked automatically, not just callable, before assuming closed** | PARALLEL | cheap (wiring) |
| 3.2 | INFRA-3490 / COTG-2.2 | finish `pr_rescue.rs`'s 2 missing arms | **registry says done (#3381, verified merged) — spot-check both arms landed, not just the debt-ceiling one already covered pre-existing** | PARALLEL | medium |
| 3.3 | COTG-2.4 | wire reactions onto the reactive bus (transport complete per original discovery, reactions absent) | PARTIAL | PARALLEL | medium |
| 3.4 | COTG-1.5 | call `gap-supervisor.sh record` from the real retry/claim loop + install the daemons (currently 0 escalation events ever, despite a prior gap claiming this was load-bearing) | PARTIAL, likely dead in practice | PARALLEL | medium |
| 3.5 | COTG-2.3 | merge-order hazard detection (cumulative-value coordination across PRs touching a shared ratchet) | NOT-FOUND | PARALLEL | strong (the exact 237/237/238 class bug) |
| 3.6 | COTG-2.5 | no-untracked-running-infra guard (plist vs `git ls-files`) | NOT-FOUND | PARALLEL | cheap |
| 3.7 | COTG-3.2 | anti-over-claim watchdog (phase marked done with open tail) | NOT-FOUND | PARALLEL | medium |

## Phase 4 — Breadth: router + remaining modes

| Order | Gap | What | Status | Serial? | Model class |
|---|---|---|---|---|---|
| 4.1 | **EFFECTIVE-330** (COTG-0.0, newly filed 2026-07-30 — spec'd in Front Door doc but never actually filed until this pass) | front-door router — clone `src/intent_parser.rs`'s shape (typed enum + pattern-match + LLM-fallback + ambient emit), swap in the 5 modes, add the confidence+confirm step neither existing parser has | DONE-HERE (skeleton) + NOT-FOUND (the 5 modes + confirm UX) | PARALLEL | strong (new UX surface) |
| 4.2 | RESCUE | generalize `src/paramedic.rs`'s fix-dispatch beyond Chump's own CI gates; translate `comprehend_tool.rs`'s technical output to plain language | diagnosis DONE-HERE (`comprehend_tool.rs` + `almanac`), actuation NOT-FOUND | PARALLEL | strong |
| 4.3 | CREATE | generalize the CREATE lap last (Front Door: "exercises the most of the spine end-to-end") | engine exists (`chump bootstrap`), full-spine wrap is new | PARALLEL | strong |
| 4.4 | COMPREHEND/INGEST | generalize through the same router+spine | engines exist | PARALLEL | cheap |

## Phase 5 — Delivery polish + wisdom/stewardship

| Order | Gap | What | Status | Model class |
|---|---|---|---|---|
| 5.1 | COTG-5.2 | fleet-state → user-language translation | NOT-FOUND, no reuse candidate | strong |
| 5.2 | COTG-5.3 | honest hand-off — compose over `intervention_watchdog`'s trailer-parsing, don't rebuild the truth-check | NOT-FOUND (thin) | medium |
| 5.3 | COTG-6.1 | trust panel | NOT-FOUND | medium |
| 5.4 | COTG-4.2 | wire `src/reflection.rs` (real, currently eval-harness-only) into the live post-execution pipeline | PARTIAL, not wired | strong |
| 5.5 | COTG-4.1 | divergent-solve (N approaches → judge → synthesize) | NOT-FOUND | strong |
| 5.6 | COTG-4.3 | **strategic comprehension — recommend re-prioritizing above P3.** This is literally the fix for "an agent acts on stale strategic context," which this session hit once live (recommending the wrong next move before finding `DOC-074`/`CHUMPOS_V1_ROADMAP.md`). The plan correctly diagnosed this risk and under-prioritized fixing it. | NOT-FOUND, currently P3 | strong |
| 5.7 | COTG-6.2, 6.3 | self-maintaining deployed tools, non-enclosure gate | NOT-FOUND | medium |

## Phase 6 — Publish

| Order | Gap | What |
|---|---|---|
| 6.1 | WS6 (V1 roadmap) | release-auditor gate → full public release |

## Throughput notes for the fleet running this

1. **Phase 1 is a bottleneck by construction** — 5 gaps, one file, must serialize. Don't
   assign more than one worker to `improve.rs` at a time; everything else in Phases 0/2-5
   can run fully parallel fleet-wide.
2. **Phase 0.3 and 2.3 aren't builds — verify/run them first**, cheap and may already
   close gaps or produce the first real readiness number with zero new code.
3. **Grafts (2.2, 4.1 skeleton, RESCUE diagnosis) are cheaper than their gap-doc AC implies**
   — route these to a fast/cheap-tier pass first (port the pattern), reserve strong-tier
   budget for the genuine NOT-FOUND builds (5.1/5.2, 4.1's divergent-solve, 3.5's
   merge-order coordination, 2.1's verification-gate judgment).
4. **Don't re-derive this matrix from scratch next session** — it's now committed; a fresh
   agent should read this file before touching COTG work, which is itself the fix 5.6 above
   is arguing for.
