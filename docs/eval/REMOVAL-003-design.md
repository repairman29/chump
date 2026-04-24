# REMOVAL-003 — Design proposal: safe `belief_state` removal

**Filed:** 2026-04-23
**Targets:** `REMOVAL-003`
**Decision source:** `docs/eval/REMOVAL-001-decision-matrix.md` (verdict: REMOVE — delta=+0.020, NEUTRAL)

## Why this needs a design doc

Audit confirms **~47 callsites across 15 src files + 1 crate**. The work is mechanical
once a design choice is made (no-op shim vs schema migration), but it touches enough
of the codebase that a botched PR could break checkpoint deserialization on disk.

This doc proposes **one atomic codemod-style PR** — not the 3+ small PRs that
CLAUDE.md's old "≤5 files" rule would suggest. See bottom of doc for the
reasoning.

---

## Audit results (2026-04-23)

### Files calling `belief_state` / `chump_belief_state`

| File | Callsites | Role |
|---|---|---|
| `src/agent_loop/types.rs` | 3 | snapshot fields in agent state struct |
| `src/agent_loop/iteration_controller.rs` | 1 | `decay_turn()` per iteration |
| `src/agent_loop/perception_layer.rs` | 2 | reads `task_belief()` for context |
| `src/agent_loop/tool_runner.rs` | 3 | `update_tool_belief()` after each tool call |
| `src/tool_middleware.rs` | 5 | `score_tools()` for tool-choice gating |
| `src/autonomy_loop.rs` | 3 | `should_escalate_epistemic()` checks |
| `src/speculative_execution.rs` | 5 | tool reliability lookup |
| `src/precision_controller.rs` | 5 | `nudge_trajectory()` |
| `src/checkpoint_db.rs` | 4 | `AutonomySnapshot` serde struct (load-bearing) |
| `src/health_server.rs` | 2 | `/health` telemetry |
| `src/routes/health.rs` | 4 | duplicate telemetry surface |
| `src/consciousness_traits.rs` | 7 | trait-level integration |
| `src/neuromodulation.rs` | 1 | trajectory nudge |
| `src/main.rs` | 1 | startup `restore_from_snapshot()` |
| `src/env_flags.rs` | 1 | `belief_state_enabled()` env gate |

### Public API surface (the crate exports)

`belief_state_enabled` · `update_tool_belief` · `decay_turn` · `nudge_trajectory` ·
`tool_belief` · `task_belief` · `snapshot_inner` · `restore_from_snapshot` ·
`score_tools` · `score_tools_except` · `should_escalate_epistemic` ·
`context_summary` · `metrics_json` · `tool_reliability` ·
types `ToolBelief` / `TaskBelief` / `EFEScore`

### Backward-compat constraint

`AutonomySnapshot` ([src/checkpoint_db.rs:94](src/checkpoint_db.rs:94)) is
serde-serialized to disk. Existing checkpoint files contain
`tool_beliefs: HashMap<String, ToolBelief>` and `task_belief: TaskBelief`
fields. Two options:

- **(A) Inline shadow types.** Define minimal `ToolBelief` / `TaskBelief`
  structs in `src/checkpoint_db.rs` itself with the same field names + serde
  derives, marked `#[serde(default)]`. Old JSON deserializes; new
  checkpoints get the fields written but they're inert. ~30 LOC, zero
  migration.
- **(B) Drop fields with serde escape hatch.** Replace the fields with
  `_belief_state_legacy: serde_json::Value` (or `#[serde(skip_deserializing,
  default)]` and ignore). Old JSON tolerated; new snapshots smaller. ~10
  LOC, slight ergonomic cost (struct has a vestigial field).
- **(C) Real migration.** Write a one-shot script that strips the fields
  from existing rows. ~200 LOC + a release-note dance.

**Proposal: (A).** Smallest change, zero migration risk, perfectly
backward-compatible. The vestigial structs add ~30 LOC that future-us can
delete in 6 months once we're confident no production checkpoints hold them.

---

## Proposed PR (single atomic codemod)

**Branch:** `claude/removal-003-belief-state`
**Files touched:** ~17 (15 src + 1 crate dir + Cargo.toml + 1 doc)
**Diff size:** ~700 LOC delete (the crate impl) + ~70 LOC add (shadow structs + 1 test)

**What changes, atomically:**

1. **`crates/chump-belief-state/`** — full directory delete.
2. **Root `Cargo.toml`** — remove workspace member entry + dep entry (2 lines).
3. **`src/belief_state.rs`** — delete the 9-line re-export shim.
4. **`src/checkpoint_db.rs`** — define inline `ToolBelief` + `TaskBelief`
   shadow structs (same field names, `#[serde(default)]`); update
   `AutonomySnapshot` to use them.
5. **15 caller files** — drop `use crate::belief_state::*` imports; delete
   `update_tool_belief()`, `decay_turn()`, `nudge_trajectory()` calls; replace
   `should_escalate_epistemic()` with literal `false`; replace `score_tools()`
   with empty `Vec::new()`; replace `task_belief()` with
   `Default::default()`; replace `tool_reliability()` with `0.5`. All
   mechanical.
6. **`docs/CHUMP_FACULTY_MAP.md`** — drop Metacognition row's belief_state
   reference.

**Tests (slim):** ONE test in `src/checkpoint_db.rs`:
`save_autonomy_checkpoint(&snapshot)` → `restore_latest_autonomy_checkpoint()`
returns the snapshot. Verifies the shadow-struct serde trick works. No new
integration tests; existing suite must stay green.

**Verification gates** (all in CI):
- `cargo check --bin chump --tests`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo fmt --check`
- The dual-surface coordination smoke test

**Risk + mitigation:**
- *If a callsite was secretly load-bearing:* `cargo test` will catch it
  (existing tests exercise tool routing + autonomy + health).
- *If `/health` consumers break:* the response loses the `belief_state`
  key. Worth a one-line release note. Low risk; nothing internal scrapes
  it that I can find.
- *If on-disk checkpoint deserialization breaks:* the shadow structs +
  serde(default) handle this. The single round-trip test verifies it.
- *If we change our mind:* `git revert <sha>` of the single PR restores
  everything.

---

## Why one PR instead of three

The earlier draft proposed PR-A (stub) → PR-B (delete callers) → PR-C
(delete crate). That's the right answer for human-driven refactors where
review burden compounds. For bot-driven work it's strictly worse:

- **CI verifies the whole change atomically.** A stub PR that compiles but
  silently changes runtime behavior is *less* safe than a single PR where
  the test suite proves end-to-end correctness.
- **No broken intermediate `main` state.** Stacked PRs leave `main` in a
  half-removed state between merges. Atomic = either old behavior or new,
  never half-and-half.
- **Cheaper revert.** One revert button vs three coordinated ones.
- **Industry pattern.** Meta's jscodeshift PRs, Google's gMock migrations,
  rust-lang's `cargo fix --edition` PRs all touch hundreds of files in one
  PR. The pattern is **codemod-shaped**: mechanical change, fully verified
  by tooling, atomic.

The CLAUDE.md "≤5 files" rule was useful when humans were the primary
reviewers. With merge-queue + required CI checks + bot-driven changes, the
correct rule is **"≤5 logically distinct intent units per PR"** — and a
single codemod is one intent unit even if it touches 17 files.

I'll propose updating CLAUDE.md to reflect this in a separate small PR
(see "Companion: CLAUDE.md update" below).

---

## Approval needed before code lands

1. **Backward-compat strategy: (A) inline shadow structs?** (My recommendation;
   alternatives are (B) skip-deserialize or (C) real migration.)
2. **Atomic single-PR shape OK?** (Or do you want stacked PRs anyway?)
3. **Anything internal scrape `/health` belief_state keys?** (If yes, give
   them a release-note heads-up.)

---

## Companion: CLAUDE.md update

If you approve the atomic-codemod approach as a general policy, I'll ship a
small CLAUDE.md update replacing:

> **Keep PRs small (≤ 5 commits, ≤ 5 files).** Hard rebases get worse, sibling-agent
> conflicts get worse, and human review gets slower with PR size. Ship narrow
> vertical slices and stack them.

with:

> **Keep PRs intent-atomic.** A PR is one logical change — a feature, a
> bug fix, a codemod, a config update. Mechanical multi-file refactors
> (renames, dead-code removal, dependency swaps) ship as a single PR no
> matter the file count, because (a) atomic = no broken intermediate `main`
> state, (b) CI verifies the whole change end-to-end, and (c) one revert
> beats coordinating three. Stack only when the changes are logically
> distinct (e.g. "land the new API, then migrate callers, then delete the
> old API"). For human-driven feature work, the old "≤5 files" heuristic
> still helps reviewers; flag the PR as "human review wanted" if so.

Sister PR.
