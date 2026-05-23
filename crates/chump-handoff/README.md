# chump-handoff

Typed contracts for parent → subagent handoffs in the Chump fleet.
INFRA-1720. v0.1.0.

## What it replaces

Today every subagent handoff is markdown:

```text
parent writes a free-form prompt
  → Agent tool spawns Sonnet/Haiku/Opus
  → subagent returns free-form text
  → parent regex-parses or eyeballs the reply
```

This is fast to write but fails three ways that all cost a full CI round-trip
(~5 min wasted) or a downstream panic:

1. **Shape drift.** Subagent returns the right *idea* in the wrong *shape* —
   missing field, extra field, wrong nesting. Parent assumes a key and panics
   later.
2. **Path hallucination.** Subagent invents a file path that doesn't exist;
   the parent tries to `git apply` and fails.
3. **Commentary contamination.** Subagent wraps the JSON we want in extra
   prose so the parent's parser chokes.

`chump-handoff` defines a typed contract per handoff site:

- `Input` (Serialize): what the parent ships to the subagent.
- `Output` (Deserialize + `Validate`): what the parent gets back, schema- and
  semantically-checked before any caller sees it.
- `HandoffContract::prompt(input)`: deterministic prompt template that
  instructs the subagent to emit a single fenced JSON block matching
  `Output`'s schema.

On any failure path the dispatch pipeline emits
`kind=handoff_contract_violation` to `.chump-locks/ambient.jsonl` with
`{contract_name, error, raw_output_first_100}` so dashboards can route
violations back to the prompt for refinement.

## Quick start

```rust
use chump_handoff::{
    contracts::{GapReviewContract, GapReviewInput},
    dispatch,
    transport::AgentToolTransport,
};

let transport = AgentToolTransport::new(); // shells out to chump-agent-cli
let input = GapReviewInput {
    gap_id: "INFRA-1720".into(),
    context: "Marcus M-D Phase 2 follow-up; touches crates/chump-team only.".into(),
};
let verdict = dispatch::<GapReviewContract>(&transport, "session-xyz", input).await?;

match verdict.verdict.as_str() {
    "approve" => { /* proceed */ }
    "revise"  => { /* fix the gap, retry */ }
    "block"   => { /* defer */ }
    _ => unreachable!("Validate guarantees the tag"),
}
```

No string parsing in user code. No `unwrap_or_else(|_| "fallback")` on a key
the subagent might have skipped. The pipeline's error type is
`HandoffError`, never `Result<_, String>`.

## The three concrete contracts (AC #3)

`crates/chump-handoff/src/contracts.rs` ships three contracts that match
real call sites we want to migrate first.

| Contract | Use case | Default tier |
|---|---|---|
| `GapReviewContract` | opus-curator second-opinion before P0 promotion | Sonnet |
| `CodeFixContract` | pr-rescue v2 "unknown failure" one-shot fix attempt | Sonnet |
| `DecomposeContract` | `chump gap decompose <ID>` typed sub-gap output | Opus |

Each contract has:

- Input + Output structs with `#[derive(Serialize)]` / `#[derive(Deserialize)]`.
- `Validate` impl that catches semantic violations (e.g. `unified_diff` must
  start with `diff --git`; `branch_name` must start with `chump/`).
- A `prompt()` template that injects the input AND explicitly tells the
  subagent the JSON shape it must emit.

## Migration path (AC #4)

The roll-out plan is **incremental and reversible**:

### Phase 1 — coexistence (v0.1; today)

- Existing markdown-prompt subagent spawns in `src/agent_factory.rs` keep
  working unchanged. They are not deprecated. No code is removed.
- New code call sites adopt `HandoffContract` types from this crate.
- A `cargo doc --open` reader for `chump_handoff` sees the three concrete
  examples and the migration guidance.

### Phase 2 — encouraged adoption (50% coverage)

- The first three Phase generators that ship under INFRA-1719's roadmap
  (Librarian, Cartographer, Evangelist) are required to use
  `HandoffContract`.
- `pr-rescue v2` (INFRA-1714 follow-up) uses `CodeFixContract` for the
  "unknown failure" path.
- `chump gap decompose <ID>` uses `DecomposeContract`.
- Once `git grep -F 'crate::dispatch_subagent_markdown(' | wc -l` is below
  the count of `HandoffContract::dispatch` call sites in the binary, we are
  >50% migrated.

### Phase 3 — deprecation (90% coverage)

- The markdown-prompt path in `src/agent_factory.rs` is marked
  `#[deprecated]` with a pointer to the matching contract.
- A CI lint warns on new uses of the deprecated path.

### Phase 4 — removal (cleanup)

- The deprecated function is removed in a `chump` minor-version bump.
- This crate's version stays at `0.x` until we have empirical numbers on
  contract-violation rates.

## Why a separate crate (not `src/handoff.rs`)

Three reasons:

1. **Reusable from `chump-coord`, `chump-orchestrator`, and the mcp-servers**
   — all of them spawn subagents. A workspace crate avoids `chump` becoming
   the cyclic dependency of every consumer.
2. **Independent versioning** — the contract shape is the public API; we
   want to be able to evolve it without forcing every consumer to rebuild
   when an unrelated `chump` change lands.
3. **Test isolation** — `cargo test --package chump-handoff` runs in <1 s,
   so contributors can iterate on contract design without the 60 s full
   workspace build.

## Observability

Every dispatch failure emits to `.chump-locks/ambient.jsonl` (or wherever
`CHUMP_AMBIENT_LOG` points):

```json
{"ts":"2026-05-23T08:12:34Z","kind":"handoff_contract_violation","contract_name":"GapReviewContract","error":"deserialize: missing field `reasoning`","raw_output_first_100":"```json\n{\"verdict\":\"approve\"}\n```"}
```

Dashboards can group by `contract_name` to spot prompts that need
refinement (high violation rate = the contract's `prompt()` is unclear).
The `raw_output_first_100` field is intentionally capped: enough for a
human to recognise the issue without leaking the full subagent payload to
ambient (PII / context-bloat concern).

## Pairs with

- **INFRA-1719** — AST crawler producing typed inputs (this is the *output*
  side of the same typed-boundary conversation).
- **INFRA-1714** — pr-rescue daemon; its "Unknown" classifier branch is the
  first natural caller for `CodeFixContract`.
- **META-061** A2A roadmap — once Layer 1a (NATS-primary delivery) lands,
  the same contract types serialise cleanly over NATS for cross-machine
  handoffs.

## What this crate is *not*

- Not a general-purpose JSON-schema enforcer (no schema generation; the
  prompt template is the schema).
- Not a workflow engine (it's a single parent → single subagent call; chain
  contracts together at the call site).
- Not coupled to any specific runner (Claude Code, opencode, codex,
  manual) — the `Transport` trait is the seam.

## Tests

```bash
cargo test --package chump-handoff
```

Includes:

- Unit tests on `extract_json_block` (fenced + bare + raw JSON, plus
  rejection of non-JSON text).
- Unit tests on each of the three contracts' `Validate` impls (positive +
  negative cases).
- Integration tests (`tests/contract_violation.rs`) for the four end-to-end
  failure modes: schema mismatch, validation failure, transport error,
  happy path. Each test isolates `CHUMP_AMBIENT_LOG` to a tempfile so they
  run cleanly in parallel.
