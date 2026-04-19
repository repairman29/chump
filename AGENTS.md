# AGENTS.md — agent guidance for Chump

This file follows the [AGENTS.md](https://aaif.io/) cross-tool convention adopted
by the Agentic AI Foundation (Linux Foundation, Dec 2025) as one of three founding
projects (alongside MCP and goose). It is the **canonical, tool-agnostic** entry
point for any agent (Claude Code, goose, Aider, Cursor, generic LLM coding tools)
working in this repo.

> **Companion file:** [`CLAUDE.md`](./CLAUDE.md) is the Chump-specific overlay
> for Claude Code and Chump-internal agents. It adds the lease/coordination
> rules, the `chump-commit.sh` wrapper, the five pre-commit guards, and other
> mechanics that are unique to this repo's multi-agent dispatcher and not
> portable to other projects. Read **AGENTS.md first**, then `CLAUDE.md` for
> Chump-specific operating procedure.

---

## Project overview

**Chump** is a Rust-based multi-agent dispatcher and coordination harness for
Claude Code (and increasingly other agent frameworks). It runs many concurrent
agent sessions against a shared codebase using lease-based file ownership, a
NATS-backed coordination bus, and a per-gap "briefing" memory system. The
workspace ships a `chump` CLI binary, several supporting crates, and a docs/
ledger that drives autonomous gap-picking.

See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the system map,
[`docs/RESEARCH_PLAN_2026Q3.md`](./docs/RESEARCH_PLAN_2026Q3.md) for current
direction, and [`docs/TEAM_OF_AGENTS.md`](./docs/TEAM_OF_AGENTS.md) for the
multi-agent design.

## Build commands

```bash
cargo build                       # debug build of full workspace
cargo build --release             # release build
cargo build --bin chump           # CLI binary only (fastest iteration)
cargo check --bin chump --tests   # type-check without codegen (use this in tight loops)
```

## Test commands

```bash
cargo test                        # full workspace test run
cargo test -p <crate>             # single crate
cargo test <name_substr>          # filter by test name
cargo test -- --nocapture         # show println! output during tests
```

## Lint and format commands

```bash
cargo fmt --all                   # format the workspace (CI runs --check)
cargo fmt --all -- --check        # what CI runs
cargo clippy --all-targets --all-features -- -D warnings
```

The pre-commit hook auto-runs `cargo fmt` on staged `.rs` files and re-stages
the result, so manual `cargo fmt` is rarely required before committing.

## Code style

- **Edition:** Rust 2024 across the workspace.
- **No `unwrap()` / `expect()` in production paths.** Tests and one-shot
  scripts may unwrap freely. Library and binary code returns `Result` and uses
  `?` or explicit `match`. Use `expect("invariant: ...")` only when documenting
  a true invariant.
- **No `panic!` outside tests.** Same reasoning.
- **Errors:** use `anyhow::Result` at binary boundaries, `thiserror` for
  library error types. Add context with `.context("doing X")?`.
- **Logging:** `tracing` (not `log`). Use structured fields, not formatted
  strings: `tracing::info!(gap_id = %id, "claimed gap")`.
- **Async:** `tokio` runtime; prefer `async fn` over manual `Future` impls.
- **Modules:** keep public surface narrow — re-export from `lib.rs` /
  `mod.rs` rather than letting callers reach into submodules.

## Where to find docs

| Doc | Purpose |
|---|---|
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | System map: crates, data flow, key types |
| [`docs/AGENT_COORDINATION.md`](./docs/AGENT_COORDINATION.md) | Lease system, branch model, failure modes |
| [`docs/TEAM_OF_AGENTS.md`](./docs/TEAM_OF_AGENTS.md) | Multi-agent design and roles |
| [`docs/RESEARCH_PLAN_2026Q3.md`](./docs/RESEARCH_PLAN_2026Q3.md) | Current research/roadmap direction |
| [`docs/gaps.yaml`](./docs/gaps.yaml) | Master gap registry (open work + closed history) |
| [`docs/INFERENCE_PROFILES.md`](./docs/INFERENCE_PROFILES.md) | Local inference (vLLM-MLX 8000 / Ollama 11434) |

## How to claim work

Chump uses a **gap registry** in `docs/gaps.yaml`. Each gap is an atomic unit
of work with a stable ID (e.g. `COMP-007`, `MEM-007`). Before starting work:

1. **Pick an open gap** — `grep -A3 "status: open" docs/gaps.yaml`.
2. **Preflight** — `scripts/gap-preflight.sh <GAP-ID>` (3s; checks done-on-main
   and live claims by sibling sessions).
3. **Claim** — `scripts/gap-claim.sh <GAP-ID>` writes a lease file under
   `.chump-locks/<session_id>.json`. **Do not edit `docs/gaps.yaml` to claim** —
   claims live in lease files only. The YAML records `status: open` /
   `status: done` and nothing else about ownership. The `CHUMP_GAPS_LOCK`
   pre-commit guard rejects writes of `in_progress` / `claimed_by` /
   `claimed_at` to the YAML.
4. **Work in a linked worktree** — `git worktree add .claude/worktrees/<name>
   -b <branch> origin/main`. Never work in the main repo root.

When the gap ships, set `status: done` + `closed_date:` in `docs/gaps.yaml`
**atomically with the implementing PR** (one commit, not a follow-up).

## Pull request guidelines

- **Branch:** `claude/<short-codename>` (or your tool's analogue, e.g.
  `cursor/<codename>`, `goose/<codename>`). Never push directly to `main`.
- **Atomic and small:** ≤ 5 commits and ≤ 5 files per PR. Big PRs lose
  commits to squash-merge races and slow down review.
- **One gap per PR.** If you find adjacent work, open a follow-up PR rather
  than expanding the current one.
- **Ship via the pipeline** — `scripts/bot-merge.sh --gap <GAP-ID> --auto-merge`
  rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and arms the
  merge queue. See `CLAUDE.md` for the Chump-specific arming/freeze rule
  (don't push to a PR after auto-merge is armed).
- **Commit messages:** conventional-commits style — `feat(<gap-id>): summary`,
  `fix(<scope>): summary`, `docs(<scope>): summary`. The gap ID in the
  commit subject lets the pre-push hook validate scope.

## Cross-tool note

Chump-internal agents read **both** `AGENTS.md` and `CLAUDE.md` (concatenated,
with `AGENTS.md` first as the canonical layer and `CLAUDE.md` as the
Chump-specific overlay). External agents that only honor the AGENTS.md
convention will get a coherent project picture from this file alone — they
won't get the lease/NATS coordination details, but they'll know the build,
test, code-style, and PR conventions.

For Cursor-specific behavior and the legacy Chump↔Cursor handoff protocol see
`docs/CHUMP_CURSOR_PROTOCOL.md` and `.cursor/rules/`. For learned user
preferences and workspace facts maintained by `agents-memory-updater`, see
`docs/CONTINUAL_LEARNING.md`.
