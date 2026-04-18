# Crates extraction plan

**Author:** Claude (autonomous-loop session, 2026-04-18)
**Status:** living document — update as crates land

This document tracks the extraction of standalone publishable crates from the `chump` monolith. The goal: ship the parts of `chump` that other agent-framework authors would actually use, on crates.io, with proper metadata + READMEs + tests.

## Method (proven on PR #94 + #95)

Each extraction follows the same template:

1. **Audit** — count LOC, list external deps, list in-bin callers
2. **Design** — confirm the module is self-contained (or list the coupling debts)
3. **Move** — copy `src/<mod>.rs` → `crates/chump-<name>/src/lib.rs`
4. **Wrap** — add `Cargo.toml` (license, repo, homepage, keywords, categories, README) and `README.md` (use case, install, API, companion crates)
5. **Re-export shim** — `src/<mod>.rs` becomes `pub use chump_<name>::*;` so all in-bin callers keep working without churn
6. **Wire** — workspace member + path dependency in root `Cargo.toml`
7. **Test** — add tests if none existed (don't ship to crates.io with zero coverage)
8. **Verify** — `cargo check --bin chump --tests` + `cargo test -p chump-<name>` + `cargo publish --dry-run -p chump-<name>`
9. **Ship** — single PR, branch-final, auto-merge enabled

## Already extracted (status)

| crate | size | published? | PR | notes |
|-------|-----:|:---:|----|-------|
| `chump-tool-macro` | ~200 | ❌ | #92 | publish-ready after polish PR lands |
| `chump-agent-lease` | ~700 | ✅ v0.1.0 → v0.2.0 pending | #93 | bump-to-publish |
| `chump-mcp-lifecycle` | ~600 | ✅ v0.1.0 → v0.1.1 pending | #93 | bump-to-publish |
| `chump-mcp-github` | ~150 | ❌ | #92 | publish-ready after polish PR lands |
| `chump-mcp-tavily` | ~150 | ❌ | #92 | publish-ready after polish PR lands |
| `chump-mcp-adb` | ~150 | ❌ | #92 | publish-ready after polish PR lands |
| **`chump-cancel-registry`** | **55** | **❌** | **#94** | extracted 2026-04-18, ready to publish |
| **`chump-perception`** | **424** | **❌** | **#95** | extracted 2026-04-18, ready to publish |

## Ranked queue (rest of the extraction work)

Each entry: name, source LOC, external value, cost (effort), coupling, blocker (if any).

### Tier 1 — small + cohesive, low risk

| # | crate | source | LOC | value | cost | coupling | blocker |
|---|-------|--------|-----|-------|------|----------|---------|
| **A** | `chump-cost-tracker` | `src/cost_tracker.rs` | ~200 | medium — Rust counterpart to the Python `cost_ledger.py`; per-provider call/token + budget warnings | xs (1 file, no deps) | none | none |
| **B** | `chump-blackboard` | `src/blackboard.rs` | 857 | **high — novel atomic exchange API for multi-agent coordination** | s (probably has SQLite ties to `chump_memory.db`; verify before extraction) | likely depends on `chump-mcp-lifecycle` or shared rusqlite Pool | maybe |
| **C** | `chump-speculative` | `src/speculative_execution.rs` | 754 | medium — speculative tool execution + rollback; useful for any agent doing speculative reasoning | s | depends on `tool_middleware` for rollback hooks | tool_middleware extraction OR keep as is and document the trait expected |

### Tier 2 — bigger but still bounded

| # | crate | source | LOC | value | cost | coupling | blocker |
|---|-------|--------|-----|-------|------|----------|---------|
| D | `chump-counterfactual` | `src/counterfactual.rs` | 1307 | medium-high — causal-lesson extraction from past episodes (the input side of the reflection framework) | m | depends on episode store (rusqlite) | extract `chump-episode-db` first OR keep coupled |
| E | `chump-reflection` | `src/reflection_db.rs` | 732 | high — but THIS IS THE THING UNDER STUDY in the n=100 sweep | m | sqlite tied to chump_memory.db | **wait for COG-016** (model-tier-gated injection) so the published v0.1 has the production-correct gating, not the unconditional version that was shown to harm |
| F | `chump-tool-middleware` | `src/tool_middleware.rs` | 1720 | medium — tool dispatch + safety gates | l | many cross-deps | high — needs tool trait extraction first |

### Tier 3 — heavy, requires DB-extraction work first

| # | crate | source | LOC | value | cost | coupling | blocker |
|---|-------|--------|-----|-------|------|----------|---------|
| G | `chump-memory` | `src/memory_db.rs` + `src/memory_graph.rs` + `src/memory_tool.rs` | 5000+ | very high externally | xl | requires extracting `chump-db-pool` (shared sqlite pool) first | hard |
| H | `chump-messaging` | `src/messaging/mod.rs` + `src/platform_router.rs` | 600+ | medium — generic platform-adapter trait | m | depends on the individual adapters (telegram/discord) | maybe |

## External crates to ADOPT (replace in-house code)

Separate from extraction — these reduce our own surface area by switching to mature crates we should depend on.

| crate | replaces | win | priority |
|-------|----------|-----|----------|
| `clap` v4 + derive | manual argv parsing in `src/main.rs` | proper subcommands, auto-help, validation | **medium** |
| `assert_cmd` + `predicates` | hand-rolled CLI integration tests | cleaner test code | low |
| `slack-morphism` | hand-rolled Slack | needed for PR #58 (COMP-004c) — sibling agent's call | (theirs to make) |
| `tokio-retry` or `backoff` | ad-hoc retry loops in API clients | exponential-backoff as config | low |
| `dialoguer` | (none currently) | first-run interactive setup wizard | low |

## Suggested execution order (post-#95 lands)

The "go slow to go fast" sequence — each one a single small focused PR, validated end-to-end before starting the next:

```
[next]  A. chump-cost-tracker        xs   ~30 min      no blocker
[then]  B. chump-blackboard           s    ~1.5 hr     audit DB ties first
[then]  C. chump-speculative          s    ~1 hr       document tool_middleware trait expected
[wait]  E. chump-reflection           m    ~3 hr       gated on COG-016 landing
[then]  D. chump-counterfactual       m    ~3 hr       depends on E pattern
[wait]  G. chump-memory               xl   ~1-2 day    needs chump-db-pool extraction first
[wait]  F. chump-tool-middleware      l    ~1 day      needs tool trait extraction first
[wait]  H. chump-messaging            m    ~3 hr       coordinate with COMP-004 work
```

Stop conditions:
- If main moves > 5 commits between extractions, rebase before the next
- If any extraction's `cargo check --bin chump --tests` fails after the wire-up, abort and investigate before pushing
- If a sibling agent files a PR touching one of these source files, pause and re-evaluate (the sibling work might supersede the extraction value)

## Companion-crate cross-reference convention

Every published crate's README ends with a "Companion crates" section linking to the others. Keep this list synced as new crates ship:

```
- chump-tool-macro        proc macro for declaring agent tools
- chump-agent-lease       multi-agent file-coordination leases
- chump-cancel-registry   request-id-keyed CancellationToken store
- chump-mcp-lifecycle     per-session MCP server lifecycle
- chump-perception        rule-based perception layer
- chump-mcp-github        MCP server for GitHub ops
- chump-mcp-tavily        MCP server for Tavily web search
- chump-mcp-adb           MCP server for Android Debug Bridge
- chump-cost-tracker      (next) per-provider call/token + budget warnings
- chump-blackboard        (next) atomic message exchange between agents
- chump-speculative       (next) speculative tool execution + rollback
- chump-reflection        (gated on COG-016) reflection / lessons store
- chump-counterfactual    (later) causal-lesson extraction
- chump-memory            (later) memory store + graph + retrieval tool
- chump-tool-middleware   (later) tool dispatch + safety gates
- chump-messaging         (later) platform-adapter trait + router
```

## Coordination

Before starting any extraction:
1. `git fetch origin main --quiet`
2. Scan worktrees: `for wt in .claude/worktrees/*/; do (cd "$wt" && git diff origin/main --name-only | grep "src/<file>.rs"); done`
3. Scan open PRs: `for pr in $(gh pr list --json number -q '.[].number'); do gh pr view $pr --json files -q '.files[].path' | grep "src/<file>.rs"; done`
4. If either is non-empty, **stop** — coordinate with the other agent or pick a different crate

This was the lesson from PRs #69/#72 being closed by the stale-pr-reaper after sibling-agent PR #71 landed first. Don't open conflicting work.
