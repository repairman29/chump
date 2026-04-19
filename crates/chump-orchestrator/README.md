# chump-orchestrator

AUTO-013 — the Chump self-dispatching orchestrator. See
`docs/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full architecture.

## Status: MVP COMPLETE (steps 1-5) + dispatch-backend pluggability (COG-025)

All five MVP steps shipped. The crate is the picker (step 1), subprocess
dispatcher (step 2), monitor loop (step 3), per-outcome reflection writes
(step 4), and the end-to-end synthetic smoke (step 5). COG-025 added the
runtime backend selector so dispatched subagents can route through Chump's
own multi-turn agent loop on any OpenAI-compatible endpoint instead of the
Anthropic-only `claude` CLI — see "Dispatch backends" below.

With `--no-dry-run --watch`, `chump-orchestrator` drives a backlog from
launch to all-PRs-merged with zero human input. Real-world dogfood (against
`docs/gaps.yaml`) and Together-vs-claude A/B is COG-026; lesson-aware
dispatch is AUTO-013-A.

## Dispatch backends (COG-025)

The dispatched-subagent binary is selected at spawn time via env:

| Env var                       | Values                       | Default  | Effect                                                                 |
|-------------------------------|------------------------------|----------|------------------------------------------------------------------------|
| `CHUMP_DISPATCH_BACKEND`      | `claude` \| `chump-local`    | `claude` | `claude` = original `claude -p` baseline; `chump-local` = `chump --execute-gap` |
| `CHUMP_LOCAL_BIN`             | path                         | _(auto)_ | Override the chump binary for the `chump-local` backend (else autodiscover `target/release/chump` walking up from worktree) |
| `OPENAI_API_BASE`             | URL                          | _(none)_ | Provider base for `chump-local` (e.g. `https://api.together.xyz/v1`)   |
| `OPENAI_MODEL`                | model id                     | _(none)_ | Provider model for `chump-local` (e.g. `Qwen/Qwen3-235B-A22B-Instruct-2507-tput`) |
| `OPENAI_API_KEY`              | secret                       | _(none)_ | API key for the OpenAI-compatible provider                              |

Both backends honour `CHUMP_DISPATCH_DEPTH=1` (depth-1 enforcement) and the
gap-claim/worktree contract. Reflection rows include `backend=<label>` in
the `notes` field so PRODUCT-006 / COG-026 A/B can split by backend.

Operator smoke against the synthetic backlog (no real network):

```bash
CHUMP_DISPATCH_BACKEND=chump-local \
  OPENAI_API_BASE=https://api.together.xyz/v1 \
  OPENAI_MODEL=Qwen/Qwen3-235B-A22B-Instruct-2507-tput \
  ./target/release/chump-orchestrator --self-test
```

### Self-test (synthetic 4-gap E2E)

```bash
chump-orchestrator --self-test
```

Runs the full pipeline in-process against
`docs/test-fixtures/synthetic-backlog.yaml`. Uses an injected
`TestSpawner` (touches a dummy file instead of forking `claude`) and a
mock `PrProvider` that returns `Shipped` for every branch. No real
network calls, no real worktrees. Completes in <10ms; CI-gated by
`crates/chump-orchestrator/tests/e2e_smoke.rs`. Use this to verify the
loop is healthy before spending real cloud calls.

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
| 4    | Reflection writes (`reflection_db` rows)  | shipped (#156)  |
| 5    | E2E smoke on synthetic 4-gap backlog      | **THIS PR — MVP COMPLETE** |

## Acceptance criteria status (vs design doc §4)

| # | Criterion                                                          | This PR     |
|---|--------------------------------------------------------------------|-------------|
| 1 | Drains 4-gap backlog, exits 0 when both PRs land                   | met (step 5, synthetic) |
| 2 | SIGINT tears down dispatched subagents cleanly                     | deferred to AUTO-013-B  |
| 3 | Simulated timeout produces `outcome=killed` reflection             | met (monitor unit test) |
| 4 | Reflections queryable via `chump --reflections`                    | met (step 4)            |
| 5 | E2E smoke on noop synthetic backlog in <10 min                     | met (actual: <10ms)     |
| 6 | `cargo clippy --workspace -D warnings` + tests pass                | met                     |

MVP complete as of step 5. The real-world smoke (against live `docs/gaps.yaml`
with the real `claude` CLI) is deferred to AUTO-013-A (lesson-aware dispatch)
where it composes with PRODUCT-006's synthesis loop. SIGINT teardown is
AUTO-013-B.

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
