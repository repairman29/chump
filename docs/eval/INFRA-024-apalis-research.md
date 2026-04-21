# INFRA-024 — apalis research (Rust-native job queue)

> Author: agent research + offline PoC, 2026-04-21.  
> Scope: evaluate [apalis](https://github.com/apalis-dev/apalis) for durable Chump infra (SQLite target, no mandatory daemon).  
> PoC: `examples/apalis-poc/` — build/run with `cargo run --manifest-path examples/apalis-poc/Cargo.toml`.

---

## Executive summary

**Verdict: hold.**

apalis is a credible, Rust-native queue with a first-class **SQLite** backend and a small, composable worker model (`WorkerBuilder` + async handler). It is a good fit for **short, idempotent, in-process or sidecar** jobs (retries, cron-shaped sweeps, bounded workflows). It is a weaker conceptual match for **Chump’s primary “job” today** — a **long-lived external agent session** (Claude Code / Cursor) where the unit of work is minutes to hours and the process boundary is outside the binary.

Recommendation: keep apalis in the **toolbox** for phase-2 slices that look like real queues (bot-merge retry backoff, stale-lease sweeper, scheduled hygiene). Do **not** anchor the core gap-dispatch architecture on it until the product story for “durable agent” is clearer (heartbeats, cancellation, human handoff).

---

## Proof-of-concept

| Item | Value |
|---|---|
| Location | `examples/apalis-poc/` (standalone `[workspace]` so it does not join the repo-root workspace) |
| Dependencies | `apalis` / `apalis-sqlite` **1.0.0-rc.7**, `tokio`, `serde` |
| `main.rs` | **~35 LOC** — `:memory:` pool, `SqliteStorage::setup`, one `push`, one worker, `ctx.stop()` after one handled job |
| Build | `cargo build --manifest-path examples/apalis-poc/Cargo.toml` |
| CI | `.github/workflows/ci.yml` — `cargo build --locked --manifest-path examples/apalis-poc/Cargo.toml` on the main `test` job |

---

## Answers to the seven research questions

### 1. SQLite alongside INFRA-023 `.chump/state.db`?

**Yes, cleanly, as a separate database file (recommended).**

apalis-sqlite owns its own migrations and `Jobs`-style tables. Merging that schema into `state.db` is *possible* (single process, `ATTACH DATABASE`, or shared pool) but couples two concerns: **gap registry / leases** vs **work queue**. Operational and migration risk go up for little gain.

**Practical default:** `.chump/state.db` for gaps/leases/intents; `.chump/apalis.db` (name TBD) for apalis only. Two files, two `sqlx::SqlitePool`s, no Postgres requirement.

### 2. Job model vs “gap execution = Claude session”?

**Partial mismatch for the headline case; good fit for sub-jobs.**

- apalis assumes **pull-based workers** consuming **serialized payloads** with retries, heartbeats, and ack semantics — excellent for **minutes-or-less** tasks or **pipelines** expressed as chained steps.
- A **gap run** is often **orchestration + human/bot session** with lifecycle outside Rust. apalis does not replace session management; it could still **enqueue** “attempt bot-merge”, “reap stale lease”, “post PR comment” as **child** jobs.

Use apalis where the job is **defined completion + idempotency**; avoid forcing “whole gap” into one apalis task unless the worker is strictly in-repo automation.

### 3. Pi mesh / worker registration?

SQLite over **NFS or shared network filesystem** for a multi-node queue is a **known footgun** (locking, latency, corruption class). apalis’s SQLite backend is best for **single-node** or **single-writer** patterns.

Reasonable mesh shapes:

- **One queue DB per node** + explicit sync/reconciliation (heavier product design).
- **One writer Pi** running workers + SQLite; others submit via HTTP/SQLite RPC (adds a daemon-ish edge — conflicts with “no mandatory daemon” unless folded into existing `chump` HTTP).

**Conclusion:** apalis does not magically solve distributed dispatch on a Pi mesh; it gives **durable local** queues unless you add infrastructure.

### 4. Maturity, MSRV, async coupling?

| Signal | Notes |
|---|---|
| Release line | **1.0.0-rc.7** at time of research — pre-1.0 API surface |
| Stack | **tokio**-centric; sqlx **0.8**, **tower** layers, **rustls** pulled via default `apalis-sqlite` / sqlx runtime features |
| MSRV / edition | Upstream crates declare **edition 2024**; Chump root remains **2021** — fine for a dependency, but teams on older stable should verify before making apalis load-bearing |
| Ecosystem | Active development under `apalis-dev`; production stories exist but are not universal — treat as **integration bet**, not a commodity like Sidekiq |

### 5. Alternatives (same problem space)

| Option | Role |
|---|---|
| **underway** | Postgres-first — ruled out for offline-first Chump |
| **fang** | Mature queue patterns; evaluate if apalis RC risk is unacceptable |
| **tokio-cron-scheduler** | Schedule-only — does not replace persistence/retries |
| **Raw sqlx + tables** | Smallest dependency footprint; you reimplement retry, visibility timeout, metrics |

**Does apalis “win”?** For **SQLite + typed jobs + middleware** without inventing a queue from scratch: **yes, on ergonomics**. For **minimal deps** or **maximum control**: raw SQL or a thinner crate may win.

### 6. Smallest high-value slice?

Ranked by ROI vs integration cost:

1. **Retry / backoff for scripted automation** (e.g. bot-merge stages) where jobs are seconds–minutes and idempotent.
2. **Cron-shaped hygiene** (stale lease reap, ambient log compaction) with apalis cron or an external trigger + `push`.
3. **Explicitly not** the first slice: rewriting gap claim/lease into apalis without a product design for session correlation.

### 7. Rip-out / unmaintained risk?

If apalis stalls: **low coupling** if the queue lives in **its own SQLite file** and only a few modules call `push` / `Worker::run`. The schema is **not** Chump’s gap schema — you can migrate rows out with SQL or drop the file. Risk rises if you merge queue tables into `state.db` and let agents hand-edit SQL across both domains.

---

## Integration cost estimate (vs today’s INFRA-023 world)

| Area | Estimate |
|---|---|
| New deps (if wired into main binary) | **apalis**, **apalis-sqlite**, plus transitive **sqlx** stack (may duplicate or align with future sqlx use in `chump`) |
| LOC | First integration likely **200–800** depending on how many shell paths move into Rust workers |
| Schema | **No change required** to `state.db` if using a sibling `.db` file |
| CI | Optional: add a job `cargo build --manifest-path examples/apalis-poc/Cargo.toml` (fast gate on API drift) |
| Operational | Workers run **inside** `chump` or a one-off binary — still **no separate queue daemon** if you accept in-process consumers |

---

## Phase-2 plan (only if we later move to “recommend”)

1. Pick queue path: **`.chump/apalis.db`** (or under `.chump/queues/`).  
2. Implement **one** production job type with metrics and structured logs.  
3. Migrate **one** shell script loop to a worker (prove retry + visibility).  
4. Document runbooks: stuck job, poison message, DLQ policy.

**Note on gap AC:** the INFRA-024 YAML bullet says “file **INFRA-025** as the concrete migration gap”; **INFRA-025 is already reserved** for “publish Rust crates”. A real migration gap should use the **next free INFRA-* id** at filing time.

---

## Why “hold” instead of “reject”

Reject would ignore a real ergonomic win for **retry-heavy automation**. Hold keeps the option open after **INFRA-023** is stable in production and we have one concrete script that clearly wants queue semantics — without committing the repo to a pre-1.0 stack prematurely.
