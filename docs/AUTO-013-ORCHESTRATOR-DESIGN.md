# AUTO-013 — Chump-Orchestrator Mode (the dogfood meta-loop)

> One Chump session reads `gaps.yaml`, picks parallel work, spawns sibling
> Chump sessions to ship it, monitors them, harvests results, and writes
> reflections back into the learning loop. The same workflow Claude Code is
> doing today when Jeff asks it to "ship the team-of-agents backlog" — but
> running inside Chump itself, with no human in the dispatcher seat.

This is the design for AUTO-013. Acceptance criteria, MVP cut, future-work
roadmap, and cross-references are at the bottom. No code ships in this PR —
this is the architectural commit that the 4-week build-out hangs off of.

## 1. The picture

The orchestrator is a thin process that drives the existing five-script
pipeline (`musher`, `gap-claim`, `gap-preflight`, `chump-commit`,
`bot-merge`) with a tokio loop in place of Jeff's hands. It is NOT a new
agent system; it's a *driver* that reads `gaps.yaml`, calls
`musher.sh --assign N` to pick parallel-safe work, spawns N `claude` CLI
subprocesses in fresh worktrees, monitors them via NATS + `gh pr list`,
harvests outcomes into `reflection_db`, and re-dispatches as PRs land.

## 2. Architectural decisions

### Q1. Dispatch model — recommendation: (c) hybrid, defaulting to (a)

External `claude` subprocess per gap (option a) for anything that writes
files / opens PRs. In-process tokio tasks (option b) only for read-only
exploration tasks. MVP ships pure-(a). Rationale: gap-claim.sh's main-
worktree guard already enforces "subagents must be separate processes in
separate worktrees", cost ledger stays clean per CHUMP_SESSION_ID, crash
isolation is the whole point.

### Q2. Subagent communication — minimal subset = chump-coord NATS subscribe + gh pr list poll

Three signals per dispatched agent: (1) "I started" via NATS INTENT
event from gap-claim.sh, (2) "I'm alive" via NATS heartbeat OR
`.chump-locks/<sid>.json` mtime fallback, (3) "I shipped/failed" via
`gh pr list --state open --json` polled every 30s. NATS gives latency;
gh pr list gives correctness. Together = minimum viable monitoring.

### Q3. Result harvesting — continuous, with concurrency cap

The orchestrator maintains an in-memory dispatch table:
`{gap_id, worktree, branch, pid, started_at, last_heartbeat_at,
pr_number?, status}`. 30-second tick: read NATS + ambient.jsonl,
update table, for each MERGED PR mark status=shipped + immediately
call musher --pick for next gap. Continuous (not wave-based) avoids
head-of-line blocking. Default cap `--max-parallel 4`.

### Q4. Failure handling — soft-deadline + reflection on every outcome

Soft deadline derived from gap effort: S=20min, M=60min, L=180min,
XL=not-auto-dispatched. Watchdog tick:
- `now - last_heartbeat_at > 5min` → mark stalled, emit ALERT
  kind=silent_subagent, do not auto-kill (might be in slow CI)
- `now - started_at > 2x soft_deadline` → SIGTERM, then SIGKILL after
  30s grace, tear down worktree via `git worktree remove --force`,
  write reflection
- Subagent exits non-zero → reflection records exit code + stderr
  tail; gap NOT auto-re-queued (avoid runaway-spend loops)
- Subagent ships PR that fails CI → orchestrator does nothing; PR
  sits open for human triage

### Q5. Recursive case — MVP = depth-1 only, hard-coded

Subagents cannot spawn further subagents in MVP. Resource sprawl
unbounded otherwise (depth 3 = 64 concurrent processes). Enforcement:
orchestrator sets `CHUMP_DISPATCH_DEPTH=1` in spawned subprocess env.
Dispatch library refuses when `CHUMP_DISPATCH_DEPTH >= 1`. Post-MVP:
depth-2 with global budget.

### Q6. Self-improvement loop — write reflections + PRODUCT-006 + eval_harness

Per dispatch, write to reflection_db:
- kind: "orchestrator_dispatch"
- gap_id, effort, domain, parallel_siblings
- prior_lessons_loaded (for eval_harness A/B)
- outcome: shipped|stalled|killed|ci_failed
- duration_seconds, pr_number, notes (auto-extracted from subagent stderr)

Three loops close on top:
1. **PRODUCT-006** runs nightly, synthesises patterns from 7 days of
   dispatch reflections ("EVAL-* gaps over-shoot deadline 60% when
   parallel_siblings >= 3"), writes lessons. Next orchestrator session
   loads lessons at startup.
2. **eval_harness** new sweep target: orchestrator_with_lessons vs
   orchestrator_no_lessons. Measures ships-per-hour, killed-rate.
   Verifies lesson loop produces better orchestration over time.
3. **MEM-006** (already filed) is the channel by which dispatched
   subagents also see accumulated lessons — closing the loop end-to-end.

This is the path to Chump getting better at orchestrating itself
without human tuning. Without (6), we have a cron-style dispatcher;
with it, we have a learning system.

## 2.5. MVP build status (5-step ship plan)

The MVP is split into five small PRs so each ships atomically:

| Step | Scope                                       | Status        |
|------|---------------------------------------------|---------------|
| 1    | `chump-orchestrator` crate + dry-run picker | **SHIPPED**   |
| 2    | Subprocess spawn (`claude` CLI per gap)     | **SHIPPED**   |
| 3    | Monitor loop (`gh pr list` poll + kill)     | **SHIPPED**   |
| 4    | Reflection writes (`reflection_db` rows)    | next          |
| 5    | E2E smoke on synthetic 4-gap backlog        | acceptance    |

Step 3 (`crates/chump-orchestrator/src/monitor.rs`) adds
`MonitorLoop::watch_until_done()` plus a `--watch` binary flag. The loop
ticks every 30s, polls `gh pr list --head <branch>` per dispatched
handle, applies the S/M/L soft-deadline ladder, and SIGTERMs+SIGKILLs
any subagent that exceeds 2× its deadline without producing a PR. The
production PR provider shells out to `gh`; tests inject a deterministic
`ScriptedProvider` so the suite never hits the network.

Step 1 shipped the `crates/chump-orchestrator/` crate with the gap-picker
filter and the `--dry-run` binary. Step 2 added the `dispatch` module:
`dispatch_gap(gap, repo_root, base_ref) -> DispatchHandle` creates a linked
worktree, claims the lease via `scripts/gap-claim.sh`, and spawns
`claude -p <prompt>` with `CHUMP_DISPATCH_DEPTH=1` set to enforce the
depth-1 rule (Q5). The binary's `--no-dry-run` flag wires it in. The
spawn path is depth-1 enforced via env var, but the orchestrator does
NOT yet wait for outcomes — that's step 3's monitor loop. The dispatch
flow is unit-tested via an injected `Spawner` trait so no real `claude`
subprocess is forked from CI.

## 3. MVP scope (1-2 weeks)

Ships under feature flag `CHUMP_ORCHESTRATOR=1` so it coexists with
human-driven workflow.

In MVP:
- New binary `chump-orchestrator` (or `chump --orchestrator`) in
  `crates/chump-orchestrator/` (or `src/orchestrator/` — decide in
  1-day spike)
- External `claude` CLI subprocess dispatch only (option (a))
- Hard-coded `--max-parallel 4`, configurable via flag
- Monitoring: NATS chump-coord watch + 30s gh pr list poll
- Failure: soft-deadline kill at 2x effort estimate, no auto-retry
- Depth-1 (env var enforcement)
- Reflection: every dispatch outcome written to reflection_db
- Documentation: docs/ORCHESTRATOR_OPS.md

Out of MVP (deferred to AUTO-013-A..D follow-ups):
- In-process fast path for read-only tasks
- Lease-file watching as NATS fallback
- Lesson-aware dispatch decisions (PRODUCT-006 wiring)
- A/B eval_harness sweep arm
- Recursive depth >1
- Cross-orchestrator coordination

## 4. Acceptance criteria for the MVP

1. `chump-orchestrator --backlog gaps.yaml --max-parallel 2` launches,
   picks 2 gaps via musher, spawns 2 claude subprocesses in 2 new
   worktrees, exits 0 when both PRs land on main
2. SIGINT cleanly tears down dispatched subagents and removes their
   worktrees (no orphan locks)
3. Simulated subagent timeout produces reflection_db row with
   outcome=killed and worktree torn down
4. Reflections queryable via `chump --reflections kind=orchestrator_dispatch
   limit=10`; at least one includes non-empty notes from subagent stderr
5. End-to-end smoke: orchestrator drains 4-gap synthetic backlog of
   noop gaps in <10 minutes, all PRs auto-merged, no human
6. cargo clippy --workspace --all-targets -- -D warnings clean;
   cargo test --workspace passes

Estimated wall time after design lands: ~10 working days for one
focused agent.

## 5. Future-work roadmap (4 weeks post-MVP)

| Week | Sub-gap | What lands |
|---|---|---|
| 1 | AUTO-013-A Lesson-aware dispatch | PRODUCT-006 lessons loaded at startup; dispatch policy reads them |
| 2 | AUTO-013-B eval_harness sweep arm | A/B with-lessons vs without; metrics: ships/hr, kill rate |
| 3 | AUTO-013-C Hybrid in-process fast path | Read-only gaps run as agent_loop tasks |
| 4 | AUTO-013-D Recursion + budget | Depth-2 dispatch with global concurrency + wall-time budget |

These four sub-gaps file as separate gap entries.

## 6. Cross-references

- `docs/TEAM_OF_AGENTS.md` — canonical contract every dispatched subagent obeys
- `crates/chump-coord/` — NATS layer the orchestrator subscribes to
- `scripts/musher.sh` (PR #113) — dispatch-policy brain orchestrator MUST call
- `scripts/gap-claim.sh` — lease-write subagents call (NOT orchestrator)
- `scripts/bot-merge.sh` — ship pipeline subagents call (NOT bypassed by orchestrator)
- `scripts/stale-pr-reaper.sh` — safety net for stuck PRs
- `src/reflection_db.rs` — schema for kind=orchestrator_dispatch row
- `src/agent_loop/` — in-process path for AUTO-013-C hybrid mode
- `docs/ADR-004-coord-blackboard-v2.md` — coordination semantics inherited
- `docs/RESEARCH_PLAN_2026Q3.md` — Q3 backlog the orchestrator drains
- PRODUCT-006 (gaps.yaml) — harvest-synthesis-lessons consumer of dispatch reflections
- MEM-006 (gaps.yaml) — agent-spawn lesson loading; dispatched subagents inherit lessons through this gap

## The single hardest unknown

How the orchestrator decides which of 60 open gaps to dispatch in what
order, when musher's current priority/effort/conflict heuristics were
tuned for a human-in-the-loop who sanity-checks each pick. Letting an
agent loop on `musher.sh --assign N` for hours unattended will surface
mis-classified gaps (effort=M that's really L, missing depends_on,
domain heuristic false-negatives) at scale and at speed.

MVP mitigation: require an `auto_dispatch_ok: true` tag on gaps before
the orchestrator will pick them. Long-term mitigation: the Q6
reflection loop teaching musher.
