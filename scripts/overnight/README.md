# scripts/overnight/

Drop-in directory for nightly research jobs. Every executable `*.sh` in here
is run by `scripts/eval/run-overnight-research.sh` once a day (default 02:00 local
via `scripts/setup/install-overnight-research-launchd.sh`).

## Why this exists

Per the 2026-04-26 directive: research churn (eval sweeps, A/B studies,
ablations) was eating daytime CPU/RAM and competing with the dispatcher's
coding agents. Move it overnight.

## Conventions

- Files named `*.sh` and marked executable run in lexicographic order
- Files ending `*.disabled` are ignored (rename to `*.sh` to enable)
- Each job runs from the repo root with a 1-hour per-job timeout (override
  with `CHUMP_OVERNIGHT_JOB_TIMEOUT_SECS`)
- A job failure does NOT abort sibling jobs — every job runs
- Per-run logs land at `.chump/overnight/<UTC-timestamp>.log`
- Overlapping runs are suppressed by `.chump/overnight.lock`
- Start/done/per-job-failure events are emitted to `.chump-locks/ambient.jsonl`
  so daytime agents can see what ran while they were asleep

## What goes here

- Eval sweeps (cargo test --release of an A/B fixture)
- Module ablation runs
- Long-form research scripts that don't need to block daytime work

## What does NOT go here

- Anything time-critical or user-facing
- Jobs that exceed 1 hour without explicitly bumping the timeout
- Anything requiring an interactive prompt

## Adding a job

1. Drop `scripts/overnight/<NN>-<short-name>.sh` (NN prefix controls order)
2. `chmod +x` it
3. Smoke-test by running it directly first
4. Verify the launchd job runs it: `launchctl start ai.openclaw.chump-overnight-research`
5. Check `/tmp/chump-overnight-research.out.log` and `.chump/overnight/<RUN_ID>.log`

## Disabling temporarily

Rename `<job>.sh` → `<job>.sh.disabled`. The wrapper skips anything that
doesn't end in `.sh`. (Keep in git so the disable is reviewable.)
