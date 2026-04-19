# chump-orchestrator

AUTO-013 — the Chump self-dispatching orchestrator. See
`docs/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full architecture.

## Status: MVP Step 1 of 5 (gap-picker + dry-run)

This PR ships only the picker scaffold. The binary reads `docs/gaps.yaml`,
applies a tiny priority/effort/dependency filter, and prints `WOULD DISPATCH:`
lines. **No subprocesses are spawned, no worktrees are created, no PRs are
opened by this binary yet.** That's coming in step 2.

### What works today

```bash
cargo run -p chump-orchestrator -- --backlog docs/gaps.yaml --max-parallel 2 --dry-run
```

Output is one summary line plus one `WOULD DISPATCH:` line per picked gap.
Exits 0 in all dry-run cases (including "nothing pickable").

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
| 1    | Gap picker + dry-run binary               | **THIS PR**   |
| 2    | Subprocess spawn (`claude` CLI per gap)   | next          |
| 3    | Monitor loop (NATS + `gh pr list` poll)   | after step 2  |
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

Step 1 is the picker scaffold only. Acceptance lights up over steps 2-5.

## Tests

```bash
cargo test -p chump-orchestrator
```

Unit tests cover: P1/P2 ordering, P3/XL/done filtering, met & unmet
dependency chains, n=0, and the empty-input edge case.
