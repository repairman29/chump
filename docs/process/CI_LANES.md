# CI Lane Model (INFRA-1379)

## Overview

The Chump CI pipeline is split into **lanes** — groups of jobs that only run
when their relevant files change.  Without lanes, a 4-line gap-YAML commit
triggers 15-25 minutes of cargo-test + clippy + audit. With lanes, the same
commit takes < 2 minutes.

## Lane Definitions

All lane outputs live in the `changes` job of `.github/workflows/ci.yml`.

| Output | Matches | Fires real jobs |
|---|---|---|
| `rust_code` | `src/**`, `crates/**`, `Cargo.*`, `chump-tool-macro/**`, `build.rs`, `tests/**` | `clippy`, `cargo-test`, `fast-checks` |
| `web_code` | `web/**`, `ChumpMenu/**` | `e2e-pwa`, `fast-checks` |
| `scripts_only` | `scripts/**` changed AND no rust/web | `audit`, `fast-checks` |
| `docs_only` | `docs/**` / `*.md` changed AND no rust/web/scripts | (stubs only) |
| `ci_config_only` | `.github/workflows/**` changed AND no rust/web/scripts/docs | `audit` |

The broad `code` output (legacy) remains and is used by jobs that haven't
been lane-narrowed yet. It matches almost everything, so it still triggers
the full suite for mixed diffs.

## Stub Pattern

Every required status check (`clippy-required`, `cargo-test-required`,
`fast-checks-required`, `audit-required`) has a pair:

```
clippy            ← real job, gates on rust_code == 'true'
clippy-stub       ← 5s pass, gates on rust_code != 'true' (PR only)
clippy-required   ← rollup: passes if either succeeds or both skipped
```

Branch protection requires `clippy-required` (not `clippy` directly).
This ensures branch protection is always satisfied without running heavy
jobs unnecessarily.

## Docs-only PRs (gap YAMLs, README updates)

For a PR that only changes `docs/**` or `*.md`:

| Job | Behaviour |
|---|---|
| `clippy` | skipped (rust_code = false) |
| `clippy-stub` | skipped (code = true, rust_code = false → both-skipped path passes) |
| `cargo-test` | skipped |
| `fast-checks` | skipped |
| `audit` | skipped (docs_only = true, INFRA-1379) |
| `audit-stub` | **passes** (docs_only = true) |
| `audit-required` | **passes** (audit-stub succeeded) |

Total wall-clock: < 2 minutes (only `changes`, `gap-status-check`,
`audit-stub`, and rollup jobs run).

## Adding a New Lane

1. Add a filter pattern in the `changes` job:
   ```yaml
   my_new_thing:
     - 'src/my_new_thing/**'
   ```
2. Add the output: `my_new_thing: ${{ steps.filter.outputs.my_new_thing }}`
3. Add an `if:` condition on the real job:
   ```yaml
   if: needs.changes.outputs.my_new_thing == 'true' || github.event_name == 'merge_group'
   ```
4. Update the corresponding stub `if:` to skip when the lane is irrelevant.
5. Document the new lane in this file.

## Disposition Gaps

Each advisory job (moved out of PR blocking) has a follow-up gap deciding
final fate: **PROMOTE** (add to required checks) or **KEEP-ADVISORY** (main-only).

- `tauri-cowork-e2e`: INFRA-1385 — promote or keep advisory
- `e2e-battle-sim`: INFRA-1386 — promote or keep advisory
- `e2e-golden-path`: INFRA-1387 — promote or keep advisory
