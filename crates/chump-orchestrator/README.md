# chump-orchestrator

AUTO-013 — the Chump self-dispatching orchestrator. See
`docs/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full architecture.

## Status: MVP Step 2 of 5 (subprocess spawn)

The crate now ships both the picker (step 1) and the subprocess dispatcher
(step 2). The dispatcher creates a linked worktree per gap, claims the lease
in that worktree via `scripts/gap-claim.sh`, and spawns a `claude -p` CLI
subprocess that follows the `docs/TEAM_OF_AGENTS.md` contract. Monitor loop
(step 3) and reflection writes (step 4) are still ahead.

### What works today

Dry-run (default — safe, no side effects):

```bash
cargo run -p chump-orchestrator -- --backlog docs/gaps.yaml --max-parallel 2 --dry-run
```

Execute (actually spawns claude subprocesses):

```bash
cargo run -p chump-orchestrator -- --backlog docs/gaps.yaml --max-parallel 2 --no-dry-run
```

The execute mode prints `DISPATCHED: <GAP> in <worktree> as PID <pid>` per
spawn and exits 0 once all spawn calls return. **It does NOT wait for the
subagents to ship** — that's step 3's monitor loop.

### Filter rules (MVP)

A gap is pickable iff:

1. `status: open`
2. `priority: P1` or `P2` (P3+ skipped until the loop is trusted)
3. `effort != xl` (XL gaps require human breakdown per design doc §4)
4. all `depends_on` IDs have `status: done`

First N in YAML order win. Reflection-driven priority tuning is AUTO-013-A.

## Roadmap — five-step MVP

| Step | Scope                                     | Status        |
|------|-------------------------------------------|---------------|
| 1    | Gap picker + dry-run binary               | shipped (#141) |
| 2    | Subprocess spawn (`claude` CLI per gap)   | **THIS PR**   |
| 3    | Monitor loop (NATS + `gh pr list` poll)   | next          |
| 4    | Reflection writes (`reflection_db` rows)  | after step 3  |
| 5    | E2E smoke on synthetic 4-gap backlog      | acceptance    |

## Acceptance criteria status (vs design doc §4)

| # | Criterion                                                          | This PR     |
|---|--------------------------------------------------------------------|-------------|
| 1 | Drains 4-gap backlog, exits 0 when both PRs land                   | NOT YET MET |
| 2 | SIGINT tears down dispatched subagents cleanly                     | NOT YET MET |
| 3 | Simulated timeout produces `outcome=killed` reflection             | NOT YET MET |
| 4 | Reflections queryable via `chump --reflections`                    | NOT YET MET |
| 5 | E2E smoke on noop synthetic backlog in <10 min                     | NOT YET MET |
| 6 | `cargo clippy --workspace -D warnings` + tests pass                | met         |

Steps 1-2 ship the picker + spawn. Acceptance lights up over steps 3-5.

## Tests

```bash
cargo test -p chump-orchestrator
```

Unit tests cover the picker (P1/P2 ordering, P3/XL/done filtering, met &
unmet dependency chains, n=0, empty input) AND the dispatcher (path
derivation, step ordering via injected `Spawner`, prompt assembly,
worktree-failure abort). The dispatcher tests use a `RecordingSpawner`
that never forks a real process — no `claude` CLI is ever invoked from
the test suite.
