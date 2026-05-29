# CI Architecture — Per-PR Isolation Guarantees

> **Scope:** documents the per-PR isolation guarantees that prevent one PR's
> CI run from poisoning another. Source-of-truth lint is
> [`scripts/ci/test-cargo-target-isolation.sh`](../../scripts/ci/test-cargo-target-isolation.sh)
> (INFRA-2118).

## Why per-PR isolation matters

The 14-day CI-rot post-mortem (DOC-063, May 2026) showed that **cross-PR
cargo target corruption** was a top-3 failure class. Two recurring symptoms:

1. **Stale `target/` artifacts from a previous PR's `Cargo.toml`** leaking
   into a new PR's incremental build — manifests as `error[E0432]: unresolved
   import` for dependencies that *are* in the current Cargo.toml.
2. **`.cargo-test-target/` and `/tmp/chump-coord-linux-build*` reuse**
   across runs — manifests as flaky failures the next PR can't reproduce
   locally because their machine has a fresh target dir.

The corruption chain is structural: by default GitHub Actions caches and the
`Swatinem/rust-cache` action share state across runs on the same runner /
within the same workflow lane. Without per-PR isolation, PR-A's
`cargo add some-crate` can leave artifacts that break PR-B's
`cargo check`.

## The two isolation layers (INFRA-2118)

### Layer 1 — per-run `CARGO_TARGET_DIR`

Every Rust job in `.github/workflows/ci.yml` declares:

```yaml
env:
  CARGO_TARGET_DIR: ${{ runner.temp }}/cargo-target-${{ github.run_id }}-${{ github.run_attempt }}
```

The `runner.temp` directory is **always** wiped between runs on
GitHub-hosted runners. The `run_id` + `run_attempt` suffix guarantees that:

- Two concurrent runs on the same self-hosted runner never share a dir.
- A re-run of the same workflow on the same SHA gets a fresh dir
  (`run_attempt` increments) — this is critical for "retry the flaky job"
  flows.
- No two PRs see each other's intermediate object files.

**Jobs covered:** `fast-checks`, `clippy`, `cargo-test`, `audit`. These are
the four jobs where `cargo build`/`cargo check`/`cargo test`/`cargo clippy`
runs. Other Rust-touching jobs (coverage, integration-test, e2e-pwa,
e2e-golden) inherit the Swatinem cache hygiene but use their own shared-key
namespaces — they may opt into per-run target dirs in a follow-up.

### Layer 2 — PR-scoped cache `prefix-key`

Every `Swatinem/rust-cache@v2` call for the four core Rust jobs declares:

```yaml
- name: Cache cargo
  uses: Swatinem/rust-cache@v2
  with:
    shared-key: ci-cargo-test  # job-class namespace
    prefix-key: "v1-pr-${{ github.event.pull_request.number || github.ref_name }}"
```

The `prefix-key` is the **outermost** cache key segment, so PRs partition
the cache namespace by PR number. Pushes to `main` and other refs fall back
to `github.ref_name` so non-PR runs share a stable cache rather than missing
constantly.

**Effect on cache reuse:**

- First PR run: cold cache (acceptable trade — DOC-063 quantified the cost
  of a flaky failure at 15min round-trip vs. ~2min cache rebuild).
- Subsequent runs on the same PR: warm cache (same prefix-key).
- A new PR opens: cold cache, no inheritance from any other PR.

The `v1-` version prefix lets us roll the entire cache namespace forward
without renaming jobs (bump to `v2-pr-...` when, e.g., the cargo version
changes incompatibly).

## What this does *not* protect against

- **Disk-full pressure on self-hosted runners** — the per-run target dirs
  accumulate until the runner cleans up. The runner-level cleanup
  (`cargo-target-reaper.sh`, INFRA-1250) handles this on a separate cycle.
  AC #3 of INFRA-2118 left explicit cleanup optional because GitHub-hosted
  runners self-wipe `runner.temp` between runs.
- **Cargo.lock conflicts at merge time** — Layer 2 keeps PR caches separate
  during in-flight builds, but the merge-time cargo lock resolution is a
  different problem owned by `pr-auto-rebase` (INFRA-1777).
- **Cross-job, same-run target sharing** — within a single workflow run,
  `fast-checks` and `cargo-test` still have *separate* target dirs (because
  `runner.temp` is per-job), but they share the same `Swatinem` cache prefix
  for their own shared-keys. That's intentional: the shared-key namespaces
  are what keep each job's cache scoped, the prefix-key just adds the PR
  partition layer on top.

## Lint enforcement

[`scripts/ci/test-cargo-target-isolation.sh`](../../scripts/ci/test-cargo-target-isolation.sh)
is run as part of `chump preflight` (INFRA-1670) and as a CI gate. It
verifies:

- `>= 4` jobs declare the per-run `CARGO_TARGET_DIR` env var (one per
  required Rust job).
- `>= 4` `Swatinem/rust-cache@v2` blocks declare the PR-scoped
  `prefix-key`.
- No stale literal target paths (e.g. `.cargo-test-target`,
  `/tmp/chump-coord-linux-build*`) appear in `ci.yml` outside of comments.

A failed lint is a structural regression — it means somebody added a Rust
job without wiring isolation, which puts us back into the DOC-063 failure
class.

## Related

- DOC-063 — 14-day CI-rot post-mortem that surfaced the top-3 failure class
- INFRA-2117 — companion: containerize cargo-test/fmt/clippy/audit on
  GitHub-hosted ubuntu (eliminates self-hosted runner pathology, separate
  axis from per-PR isolation)
- INFRA-1250 — `cargo-target-reaper.sh` (disk-pressure cleanup on
  self-hosted runners)
- INFRA-1374 — historical: per-worktree CARGO_TARGET_DIR mutex isolation
  (local-dev parallel `cargo build` racing); INFRA-2118 is the CI-side
  generalization
- INFRA-1670 — `chump preflight` (local-CI parity wrapper that runs this lint)
