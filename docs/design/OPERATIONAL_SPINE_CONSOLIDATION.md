# Operational Spine Consolidation — promote `chump-fleet` to the one supervised node daemon

**Status:** scoped (2026-08-10), delivered to the fleet. Strangler-fig, not a rewrite.

## The problem (measured, not asserted)

ChumpOS's Rust core is solid, but its *operational nervous system* is shell held
together by convention, and it shatters under load. Measured on `origin/main`:

- **78,844 lines of bash** in `scripts/{coord,ops,dispatch}` (414 scripts).
- **260 of those scripts mutate canonical state** — `state.db`, `ambient.jsonl`,
  `.chump-locks/`, `chump gap reserve/set`. By the fleet's **own rule (META-064:
  Rust-first if it mutates canonical state / is a hot path / is a daemon)** these
  must be Rust. They are not. This is ~79k lines of rule-violating operational debt.
- **~36 recovery/coordination daemons** run as independent **launchd + systemd
  units**, deployed and coordinated **over ssh**, watched by a **bash** farmer.
- almanac resolved only **501 of 2,564** dependency edges — most coupling runs
  through shell invocation and is invisible to static analysis (and to reasoning).

Every failure in the 2026-08-10 operator session lived in this layer: env races
(`HOME` unbound), ssh-quoting breakage, daemon-lifecycle drift (recovery daemons
present on the Mac, absent on the primary node), gap-filing flakiness, pgrep
self-match, no back-pressure. **The empty conductor's chair the mission promises is
impossible on top of glass — a human is required precisely because the spine
shatters.** Robustifying it is not cleanup; it is the path to real autonomy.

## Mine-before-build — the pieces already exist

**Do NOT build a supervisor from scratch.** Build on what's there:

| Exists | What it already does |
|---|---|
| `crates/chump-coord/src/bin/chump-fleet.rs` | **Rust supervisor kernel** — spawns N workers as supervised tokio tasks with restart-backoff + shutdown channels. Today it supervises ONLY workers. |
| `crates/chump-curator-supervisor` | Rust supervisor for curator roles (still respawns via tmux/bash — a half-migration to learn from). |
| `crates/chump-gap-store`, `chump-coord`, `chump-agent-lease`, `chump-atomic-claim` | **Typed replacements for the 260 bash state-mutators** already exist as crates. |

The supervisor and the typed state layer both exist. What's missing is that they
**own the spine** instead of a handful of workers.

## The design — one supervised process per node

Promote `chump-fleet` from "worker supervisor" to **the single long-lived node
daemon** that owns three things, in-process, typed, and tested:

1. **Workers** (has today) — spawn/restart/backoff/shutdown.
2. **Recovery + coordination daemons** — the ~36 launchd/systemd units become
   **internal supervised timers/tasks** inside `chump-fleet`. No launchd, no
   systemd sprawl, no ssh-glue, no bash farmer watching labels — the supervisor
   watches its own children. (This session's 6 — pr-lander, pr-triage,
   back-pressure, conductor, heartbeat-monitor, ci-flake-rerun — are the first
   cohort; they were literally deployed by hand-ssh tonight, which is the disease.)
3. **State mutation** — the 260 scripts call the typed crates
   (`chump-gap-store`, `chump-coord`, `agent-lease`, `atomic-claim`) instead of
   `sqlite3`/`chump gap …`/`printf >> ambient.jsonl` from bash.

**Node-aware:** the supervisor reads the node's capability profile (Node Fabric,
`docs/design/NODE_FABRIC.md`) and runs only the roles this node should — so a fresh
node comes up with its recovery layer already inside one process, not ssh'd in
after the fact (the RESILIENT-289 / "Mac-only daemons" wound).

## Strangler-fig migration (measurable, reversible)

- **Phase 1 — absorb the daemons.** Move the ~36 recovery daemons into
  `chump-fleet` as supervised internal timers, highest-churn first (pr-lander,
  triage, back-pressure, conductor, reaper, flake-rerun, farmer's watchdog role).
  Retire each launchd/systemd unit in the same PR that lands its in-process form.
  **Metric: daemon-units per node 36 → 1.**
- **Phase 2 — node-aware supervision.** Supervisor consumes the node capability
  profile; roles start by policy, not by hand-install.
- **Phase 3 — type the state mutators.** Migrate the 260 state-touching scripts
  to typed crate calls, retire the scripts. **Metric: state-mutating bash 260 → 0.**
- **Phase 4 — retire the launchers.** `run-fleet.sh`, `farmer.sh`,
  `fleet-autorestart-daemon.sh`, and the ssh-based deploy path are deleted once the
  supervisor owns their function. **Metric: bash LOC in coord/ops/dispatch ↓ from 79k.**

Each phase ships behind the supervisor already running — the fleet never stops.

## What stays shell (explicitly)

Leaf glue is fine: one-shot `gh`+`git`+`jq` scripts, CI test fixtures, exploratory
tooling that mutates no canonical state and crosses no process boundary (META-064's
"shell-OK" column). This is a consolidation of the **load-bearing spine**, not a
crusade against bash.

## Why this is the bet
It is the direct enabler of the mission's headline claim ("no human in the
conductor's chair") and the fix for the entire class of operational fragility that
required a human all night. Related: META-064 (the rule this enforces), the
crate-extraction campaign (`docs/process/WHEN_TO_CRATE.md`), Node Fabric
(`docs/design/NODE_FABRIC.md`), RESILIENT-289 (recovery-daemons-on-primary-node).
