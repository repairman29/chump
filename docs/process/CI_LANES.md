# CI Lanes — Chump CI Structure

This document describes the parallel and sequential structure of Chump's GitHub Actions CI workflow (`.github/workflows/ci.yml`).

## Overview

The CI pipeline is built around a **required-check rollup** model: branch protection enforces a small set of required status checks, each backed by a lightweight rollup job that aggregates multiple parallel/sequential shards.

```
pull_request event
       │
       ├── changes (path filter)
       │
       ├── fast-checks ──────────────────────────────────────────► fast-checks-required
       ├── fast-checks-stub (no-code PRs) ──────────────────────► fast-checks-required
       │
       ├── clippy ───────────────────────────────────────────────► clippy-required
       ├── clippy-stub (no-code PRs) ────────────────────────────► clippy-required
       │
       ├── cargo-test-fast  ────────────────────────────────────┐
       │       │                                                 │
       │       └──► cargo-test-slow (only if fast passes) ──────┤► cargo-test-required
       ├── cargo-test-stub (no-code PRs) ───────────────────────┘
       │
       └── pr-hygiene ──────────────────────────────────────────► test (main rollup)
```

The top-level `test` required check aggregates `fast-checks`, `clippy`, `cargo-test`, and `pr-hygiene` in parallel. Each shard has its own `-required` rollup so branch protection can enforce them individually if needed.

---

## Fast vs Slow Test Tiering (INFRA-1380)

### Motivation

The pre-INFRA-1380 `cargo test --workspace` ran all unit and integration tests in a single job. On slow CI VMs with the full workspace (including `chump-desktop` with webkit deps), this took 10–15 min wall-clock. A compile error or trivial unit test regression forced the full wait before feedback arrived.

**INFRA-1380** splits Rust tests into two sequential tiers gated on the fast tier's outcome:

| Tier | Job | Command | Target wall-clock |
|------|-----|---------|-------------------|
| Fast | `cargo-test-fast` | `cargo test --workspace --lib --bins` | < 3 min |
| Slow | `cargo-test-slow` | `cargo test --workspace --tests` | < 15 min |

### Dependency chain

```
cargo-test-fast
      │
      └── (if: result == 'success')
              │
              ▼
       cargo-test-slow
              │
              └── (always)
                      │
                      ▼
             cargo-test-required
```

- **`cargo-test-slow` only runs if `cargo-test-fast` succeeded.** This means a unit test failure surfaces in ~3 min and skips wasted integration time.
- **`cargo-test-required`** needs both tiers (plus the `cargo-test-stub` for no-Rust PRs). It emits a clear error distinguishing "fast tier failed" from "slow tier failed" to help triage.

### What goes in each tier

**Fast tier (`--lib --bins`):**
- All `#[test]` functions inside `src/` (unit tests, inline doc tests excluded by `--lib`)
- Binary smoke tests compiled into `src/bin/`
- Does NOT run files in `tests/` or `crates/*/tests/`

**Slow tier (`--tests`):**
- All integration test files in `tests/` at the workspace root
- All integration test files in `crates/*/tests/`
- Examples: `tests/cli_fleet_coord.rs`, `crates/chump-coord/tests/`, `crates/chump-orchestrator/tests/`

### Timing output

Both jobs emit ISO-8601 timestamps at start and end of the cargo test step:

```
fast-tier-start: 2026-05-15T12:00:00Z
...
fast-tier-end:   2026-05-15T12:02:47Z
```

Use these to verify the <3 min target is met. If the fast tier drifts above 3 min, move the slowest test modules into the slow tier.

### Stub path (no-code PRs)

For PRs that touch only docs, scripts, or YAML (detected by `changes.outputs.code != 'true'`), `cargo-test-stub` fires instead of either real tier. The stub passes in <10 s and satisfies the `cargo-test-required` branch protection check.

### Compat shim

The existing `test` rollup job (required check, cannot rename without branch-protection admin edit) references `cargo-test` in its `needs` list. A lightweight `cargo-test` shim aggregates `cargo-test-fast` and `cargo-test-slow` and forwards the combined result so the rollup continues to work without config changes.

---

## Other CI lanes

### fast-checks

Runs `cargo fmt --check`, `cargo doc --no-deps`, and other cheap compile-time checks. Target: <2 min. Always parallel with `clippy` and `cargo-test-fast`.

### clippy

`cargo clippy --workspace -- -D warnings`. Target: <5 min. Parallel with `cargo-test-fast`.

### pr-hygiene

Validates PR metadata (title format, linked gap, label hygiene). Path-filter-agnostic — runs on every PR.

### coverage (non-blocking)

`cargo llvm-cov` — uploads an lcov artifact and writes a summary. `continue-on-error: true`; not a merge-blocker. Target: <45 min.

---

## Adding a new required check

1. Add the real job + a `-stub` job gated on `changes.outputs.code != 'true'`.
2. Add a `-required` rollup that `needs: [real-job, stub-job]` and `if: always()`.
3. Wire the `-required` rollup into the `test` rollup `needs` list **or** add it as a separate branch protection required check.
4. Do NOT delete or rename existing jobs without a branch-protection admin edit.

---

## CI test

`scripts/ci/test-cargo-test-tiered.sh` — asserts the two-tier job structure is intact in `ci.yml`. Run locally with:

```bash
bash scripts/ci/test-cargo-test-tiered.sh
```
