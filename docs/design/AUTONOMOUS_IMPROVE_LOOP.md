# Autonomous External-Repo Improve Loop — Architecture

**Gap:** EFFECTIVE-177 · **Status:** shipped (PR #TBD) · **Proving ground:** repairman29/BEAST-MODE

## Mission

Chump — not the operator, not an Opus "in a trenchcoat" — reads an external repo,
picks *real* work, **proves** it, and **self-merges on merit**. No human in the loop.
A pushed PR ≠ good code ≠ a merge. The product is the *trust*, and trust is built
from verification you can't fake.

## Architecture: thin orchestrator (Mode-D external path)

`chump improve <owner/repo> [--gap <ID>] [--apply] [--clone-dir <path>]`

Implemented in `src/improve.rs`, wired in `src/main.rs`.

**This is NOT an extension of `crates/chump-integrator/src/cycle/`.** That cycle
deliberately excludes external-repo gaps (`select.rs` `.filter(|e|
!e.is_external_repo())`), which is intentional per INFRA-2113 ("Mode D handled
separately"). The improve orchestrator is the Mode-D external path and lives
alongside `src/onboard.rs`, not inside the integrator.

## 4-stage chain — assembly of existing pieces

```
chump improve owner/repo --apply
      │
      ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ Stage 1: PICK                                                 │
  │   read_latest_scan(~/.chump/external/<owner>/<repo>/scans/)  │
  │   → ProposedGap (highest confidence)                          │
  │   reuses: chump_handoff::external_repo_schema::{OnboardScan, │
  │            ProposedGap, SourceOfEvidence}  (EFFECTIVE-166)   │
  └──────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ Stage 2: DEDUP  (ZERO-WASTE-006)                              │
  │   grep clone + git log for gap keywords                       │
  │   → redundant? emit kind=redundant_work_skipped, exit 0      │
  │   → not redundant? proceed                                    │
  └──────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ Stage 3: IMPLEMENT                                            │
  │   ExternalRepoContract::prompt(ExternalRepoInput)             │
  │   → spawn claude -p --dangerously-skip-permissions            │
  │        --model claude-sonnet-4-5                              │
  │   in clone_dir (same spawn pattern as dispatch.rs)            │
  │   → extract pr_url from agent JSON output                     │
  │   binary: CHUMP_IMPROVE_CLAUDE_BIN (default: claude)          │
  └──────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ Stage 4: VERIFY-MERGE  (CREDIBLE-096)                         │
  │   delegate to: chump external verify-merge                    │
  │     --pr <N> --repo <owner/repo> --gap <ID> [--apply]        │
  │   gates: CI green + anti-cosmetic test proof + no-regression  │
  │   self-merges ONLY on merit (orchestrator does NOT re-impl)   │
  │   binary: CHUMP_IMPROVE_CHUMP_BIN (default: auto-resolve)    │
  └──────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
  emit kind=improve_cycle_complete
    {repo, gap, verdict: dry_run|verified|held, pr}
```

## Dry-run vs --apply

| Mode | Stage 1 | Stage 2 | Stage 3 | Stage 4 |
|---|---|---|---|---|
| dry-run (default) | runs | skipped | skipped | skipped |
| --apply | runs | runs | runs | runs |

Dry-run prints the planned chain and the scout's top pick without touching the repo.

## Existing pieces composed (not reinvented)

| Need | Reused piece | Location |
|---|---|---|
| Proposal schema w/ evidence | `OnboardScan` + `ProposedGap` + `SourceOfEvidence` | `crates/chump-handoff/src/external_repo_schema.rs` |
| Read latest scan | `read_latest_scan()` | `crates/chump-handoff/src/external_repo_schema.rs` |
| Agent prompt | `ExternalRepoContract::prompt()` | `crates/chump-handoff/src/contracts.rs` |
| Agent spawn pattern | `Command::new(claude_bin).arg("-p").arg(prompt).arg("--dangerously-skip-permissions")` | mirrors `dispatch.rs::spawn_headless` |
| Verify-merge logic | `chump external verify-merge` (all 3 gates) | `src/external_verify_merge.rs` (CREDIBLE-096) |
| Ambient emit | `crate::ambient_emit::emit()` | `crates/ambient-cli/` |

## Redundancy discipline (both directions, META-063)

**Target-side** (Chump working in the external repo): the dedup stage (Stage 2)
checks the work is not already done before `--apply` proceeds. Heuristics:
- `git log --oneline -50` for exact title-core match in recent commits
- `grep -r` for all top-3 title keywords present in the codebase

Neither check is advisory — a redundant result emits `kind=redundant_work_skipped`
and the orchestrator exits 0 (correctly skipped, not an error).

## Env vars

| Var | Default | Purpose |
|---|---|---|
| `CHUMP_IMPROVE_CLAUDE_BIN` | `claude` | Path to claude CLI (test injection) |
| `CHUMP_IMPROVE_GH_BIN` | `gh` | Path to gh CLI, forwarded to verify-merge |
| `CHUMP_IMPROVE_CHUMP_BIN` | auto-resolve | Path to chump binary for verify-merge |
| `CHUMP_IMPROVE_DISABLED` | unset | Category-B kill-switch (set to `1` to disable) |

Documented in `scripts/ci/env-vars-internal.txt`.

## Ambient events

| Kind | When | Fields |
|---|---|---|
| `improve_cycle_complete` | end of every cycle | `repo`, `gap`, `verdict`, `pr` (if any) |
| `redundant_work_skipped` | dedup stage fires | `repo`, `gap`, `reason` |

Reserved in `scripts/ci/event-registry-reserved.txt`.

## Test coverage

- **Rust unit tests** (`src/improve.rs` `#[cfg(test)]`): pick, dedup-redundant,
  dedup-notredundant, pr_url extraction, pr_number extraction, dry-run chain,
  --apply flag parsing. Run via `cargo test`.
- **Shell integration test** (`scripts/ci/test-chump-improve.sh`): full binary
  test with stub `claude`/`gh`/`chump` binaries injected via env vars. Tests
  --help, dry-run, dedup-skip, and --apply chain. Registered in CI as
  "chump improve orchestrator — 4-stage mock chain (EFFECTIVE-177)".

## Prior art checked (META-063 build-side redundancy gate)

| Considered | Verdict |
|---|---|
| `crates/chump-integrator/src/cycle/` | Excluded by design — INFRA-2113 |
| `src/onboard.rs::run_inner` | Reused schema; scan path not directly callable as library fn; orchestrator calls `read_latest_scan` directly |
| `src/dispatch.rs::spawn_headless` | Pattern reused (not the fn — dispatch.rs is tightly coupled to `Workspace`/`Opts` internals) |
| `src/external_verify_merge.rs` | Delegated to (not reimplemented) |

## Proving ground

First target: `repairman29/BEAST-MODE` — make the existing test suite run + pass
in CI. High-value, verifiable, bootstraps verifiability for every future autonomous
merge (the loop strengthens its own footing).

Demo thesis: *Chump took BEAST-MODE from tests-that-don't-run to
tests-that-gate-every-change, verified it against a bar a cosmetic change can't
fake, and merged it itself — no human touched it.*
