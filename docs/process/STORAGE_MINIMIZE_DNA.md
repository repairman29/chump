# Storage-minimize DNA (RESILIENT-323)

Honest audit (Jeff, 2026-08-19): REACTIVE reaping is deep in Chump's DNA (22
reapers). FOOTPRINT-CAPPING (ZERO-WASTE-053 `cargo-sweep-gc`) was designed but
sat on the shelf until 2026-08-19. LEARNING/adaptive optimization was not in
the DNA at all. This doc records what RESILIENT-323 adds and the evaluation
behind the pieces that aren't full implementations.

## 1. REDUCE the need (not just reap residue)

| Lever | State before RESILIENT-323 | State after |
|---|---|---|
| Bounded shared `target/` | `cargo-sweep-gc.sh` existed (ZERO-WASTE-053) but had no adaptive cap | Still the enforcement point — now sourced from an adaptive, disk-aware budget (§2) |
| Local sccache | `scripts/setup/install-sccache.sh` existed (macOS/brew) but wasn't in `bootstrap-manifest.yaml` — CI had `mozilla-actions/sccache-action`, local dev/fleet nodes did not, so "shared cache" only applied inside a single CI run | `sccache-local` manifest entry (macOS) below; Linux fleet nodes (RESILIENT-318 organ hosts) get sccache via `cargo install sccache` in the same idempotent check/install shape |
| docs/archive + old logs | Uncompressed; `docs/archive/eval-runs` alone was 4.4M of `.jsonl`/`.json` fixtures | `scripts/ops/compress-stale-archive.sh` — safety-checked gzip (skips anything still referenced elsewhere in the tracked tree); ran once in this PR against `docs/archive` (44 files, ~2MB) |
| workspace-hack / hakari | Not evaluated | Evaluated below — **not adopted in this PR** |

### hakari evaluation

`cargo hakari` generates a `workspace-hack` crate that unifies feature
resolution across workspace members so `cargo check`/`clippy` doesn't
recompile the same dependency with different feature sets per crate.

- Workspace size: 41 members (`crates/*` + `desktop/src-tauri` + the
  `chump-tool-macro` proc-macro crate) — large enough that hakari's unify-features
  win is plausible.
- Baseline measured this session: `cargo check --workspace` (warm target,
  post cargo-sweep-gc plateau) = ~92s wall.
- **Decision: defer, don't adopt yet.** hakari needs a `workspace-hack`
  crate committed + `cargo hakari generate` re-run on every `Cargo.toml`
  dependency change, enforced by a CI check (`cargo hakari verify`) — that's
  a new CI gate + a new pre-commit dependency-drift class, not a
  drop-in win. Given this gap's `m` effort budget, the safer sequencing is:
  ship the adaptive layer (§2, the actual gap per the notes) now, and file
  hakari adoption as its own follow-up so it gets a real before/after
  `cargo check --workspace` timing comparison and its own CI-gate design
  rather than being folded in here unverified.
- Follow-up: `chump gap reserve --domain ZERO-WASTE --title "adopt cargo-hakari workspace-hack crate"` once someone has bandwidth to do the before/after measurement properly.

## 2. ADAPTIVE layer — the real gap

`scripts/ops/storage-footprint-optimizer.sh`:

- **SENSE** — snapshots `target/`, the sccache dir, `docs/archive`, disk-free,
  and core count into `~/.chump/storage-footprint-history.jsonl` (self-bounded
  to the last `CHUMP_STORAGE_HISTORY_MAX` snapshots — the learner itself
  can't become an unbounded-growth organ).
- **LEARN** — compares the latest snapshot against the oldest one inside a
  `CHUMP_STORAGE_LOOKBACK_DAYS` (default 7) window to derive a growth rate in
  MB/day per organ.
- **BUDGET** — derives:
  - `CHUMP_CARGO_TARGET_CAP_MB`: disk-aware (never more than
    `CHUMP_STORAGE_DISK_FRACTION` × current free disk), growth-aware
    (nothing today — cap is disk-driven; growth feeds the TTL instead).
  - `CHUMP_CARGO_SWEEP_TIME_DAYS`: tightens from the 14-day default toward a
    3-day floor as `days-to-fill-the-cap` (`cap / growth_rate`) shrinks — a
    node growing its target dir fast gets pruned more often instead of
    sawtoothing against a fixed-size cap.
  - `SCCACHE_CACHE_CAP_GB`: cores-aware (`5 + cores/2`, capped at 30GB) and
    disk-bounded the same way as the target cap.
- **WRITE + ENFORCE** — writes `~/.chump/storage-footprint-budget.env` using
  `: "${VAR:=computed}"` assignments. `cargo-sweep-gc.sh` and
  `sccache-reaper.sh` source this file (if present) before reading their own
  env-var defaults — so the optimizer's output is the enforcement path
  through the *existing* reapers rather than a parallel eviction mechanism.
  An explicit caller-set env var always wins; an absent/stale budget file is
  a harmless no-op (the reapers keep their hardcoded defaults).

This closes the "fixed thresholds regardless of node" gap named in the AC:
a node with little free disk gets a small, frequently-pruned target dir; a
node with headroom and many cores gets a bigger cap and a bigger sccache
allowance.

## 3. Verification (AC #3 — days-long plateau)

A CI/session-scoped check cannot prove multi-day behavior directly. What's
verifiable now and what closes the loop over time:

- `scripts/ci/test-storage-footprint-optimizer.sh` proves the SENSE/LEARN/BUDGET/WRITE
  contract deterministically: synthetic history fixtures assert the cap
  shrinks under fast growth + tight disk, and that the budget file's
  `:=`-assignments don't clobber an explicit caller override.
- `scripts/ci/test-compress-stale-archive.sh` proves the reference-safety
  check (a referenced file is never compressed) and the git-age gate.
- Ongoing plateau proof is the job of `kind=storage_footprint_budget`
  (emitted every optimizer tick) plus the existing `kind=cargo_sweep_gc_ran` /
  `kind=sccache_reaped` events — `fleet-brief`/`disk-health-monitor` already
  consume `disk_free_gb`-tagged events (see EVENT_REGISTRY.yaml), so a node
  whose `target_mb`/`sccache_mb` series (in `storage-footprint-history.jsonl`)
  stops trending up over days is the observable proof the AC asks for. That
  history file is the honest artifact to check after this has run for days
  on a real node — this PR wires the sensing + enforcement; the multi-day
  proof accrues after it's been running.

## Organs wired (RESILIENT-318 housekeeping + macOS bootstrap-manifest)

- `storage-footprint-optimizer` — hourly organ in `install-node-housekeeping.sh`
  (Linux/systemd/runit/nohup fleet nodes).
- `archive-compress` — daily organ (runtime-logs mode only; docs-archive mode
  is intentionally a manual/PR-time action, not automated, since it mutates
  git-tracked files).
- `sccache-local` — new `bootstrap-manifest.yaml` P2 entry (macOS) — installs
  `scripts/setup/install-sccache.sh` if `.cargo/config.toml` doesn't already
  set `rustc-wrapper = "sccache"`.
