# chump-orchestrator

AUTO-013 — the Chump self-dispatching orchestrator. See
`docs/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full architecture.

## Status: MVP Step 4 of 5 (reflection writes)

The crate now ships the picker (step 1), subprocess dispatcher (step 2),
the monitor loop that watches each dispatched subagent until it reaches
a terminal outcome (step 3), and per-outcome reflection writes (step 4 —
this PR). The end-to-end smoke (step 5) is the only remaining MVP step.

Step 4 closes the self-improvement loop spec'd in
`docs/AUTO-013-ORCHESTRATOR-DESIGN.md` §Q6: every dispatch outcome lands
in `chump_reflections` + `chump_improvement_targets` with
`error_pattern = 'orchestrator_dispatch'` and a structured `directive`
of the shape `dispatched gap=… effort=… outcome=… duration_s=…
parallel_siblings=… pr_number=… notes=…`. PRODUCT-006 (nightly
synthesis) reads these rows and distils higher-priority lessons; MEM-006
surfaces those lessons inside the next dispatched subagent's prompt.

Stderr capture: while a subagent runs, a background tailer thread keeps
the last 64 WARN/ERROR/FAIL/PANIC lines in a bounded ring. The snapshot
is folded into the reflection's `notes` field on terminal outcome.

The monitor (`crates/chump-orchestrator/src/monitor.rs`) ticks every 30s
per `DispatchHandle`, probing both the child PID (via `try_wait`) and the
PR state (via `gh pr list --head <branch> --state all`). It applies the
soft-deadline ladder from the design doc — S=20m / M=60m / L=180m — and
SIGTERMs (then SIGKILLs after 30s grace) any subagent that has no PR by
2× the soft deadline. The PR probe is behind a `PrProvider` trait so the
state machine is unit-tested without shelling out to `gh`.

### What works today

Dry-run (default — safe, no side effects):

```bash
cargo run -p chump-orchestrator -- --backlog docs/gaps.yaml --max-parallel 2 --dry-run
```

Execute (actually spawns claude subprocesses, returns immediately):

```bash
cargo run -p chump-orchestrator -- --backlog docs/gaps.yaml --max-parallel 2 --no-dry-run
```

Execute and watch (spawns + blocks on the monitor loop until every
dispatched subagent reaches a terminal outcome — Shipped, Stalled,
Killed, or CiFailed):

```bash
cargo run -p chump-orchestrator -- --backlog docs/gaps.yaml --max-parallel 2 --no-dry-run --watch
```

The execute mode prints `DISPATCHED: <GAP> in <worktree> as PID <pid>` per
spawn. With `--watch` it then prints a summary table when the monitor loop
returns (one line per dispatched gap with its terminal outcome).

### Filter rules (MVP)

A gap is pickable iff:

1. `status: open`
2. `priority: P1` or `P2` (P3+ skipped until the loop is trusted)
3. `effort != xl` (XL gaps require human breakdown per design doc §4)
4. all `depends_on` IDs have `status: done`

First N in YAML order win. Reflection-driven priority tuning is AUTO-013-A.

## Roadmap — five-step MVP

| Step | Scope                                     | Status          |
|------|-------------------------------------------|-----------------|
| 1    | Gap picker + dry-run binary               | shipped (#141)  |
| 2    | Subprocess spawn (`claude` CLI per gap)   | shipped (#145)  |
| 3    | Monitor loop (`gh pr list` poll + kill)   | shipped (#152)  |
| 4    | Reflection writes (`reflection_db` rows)  | **THIS PR**     |
| 5    | E2E smoke on synthetic 4-gap backlog      | next (final)    |

## Acceptance criteria status (vs design doc §4)

| # | Criterion                                                          | This PR     |
|---|--------------------------------------------------------------------|-------------|
| 1 | Drains 4-gap backlog, exits 0 when both PRs land                   | NOT YET MET |
| 2 | SIGINT tears down dispatched subagents cleanly                     | NOT YET MET |
| 3 | Simulated timeout produces `outcome=killed` reflection             | NOT YET MET |
| 4 | Reflections queryable via `chump --reflections`                    | met (step 4) |
| 5 | E2E smoke on noop synthetic backlog in <10 min                     | NOT YET MET |
| 6 | `cargo clippy --workspace -D warnings` + tests pass                | met         |

Steps 1-4 ship the picker, spawn, monitor, and reflection persistence.
Only the final E2E smoke (step 5) remains.

## Tests

```bash
cargo test -p chump-orchestrator
```

Unit tests cover the picker (P1/P2 ordering, P3/XL/done filtering, met &
unmet dependency chains, n=0, empty input), the dispatcher (path
derivation, step ordering via injected `Spawner`, prompt assembly,
worktree-failure abort), and the monitor (soft-deadline table, every
branch of the pure `decide_tick` state machine, plus
`MonitorLoop::watch_until_done` driven by a `ScriptedProvider` mock).
The CLI smoke tests also exercise `--watch` against an empty backlog to
prove the wiring without forking a real `claude` subprocess. No `claude`
binary or live `gh` invocation is needed to run `cargo test`.
