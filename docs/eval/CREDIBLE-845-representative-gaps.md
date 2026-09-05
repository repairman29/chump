---
doc_tag: log
owner_gap: CREDIBLE-845
last_audited: 2026-09-05
---

# Representative gaps for model-tier grading (CREDIBLE-230 slice)

**Parent:** CREDIBLE-230 ("inference test kit" — measure whether best models can
make chump write/edit/ship/merge unaided, not just free-tier models).

**Purpose of this doc:** CREDIBLE-230 calls for "a fixed set of representative
gaps (xs/s/m effort, across at least Rust and TS) run end-to-end — claim ->
edit -> commit -> PR -> CI green -> merge — with the SAME gap attempted per
model tier so results are comparable." This doc *is* that fixed set. It does
not run the harness or report results (that's CREDIBLE-230 proper, effort L);
it only defines the gaps so a future harness run has something concrete and
reusable to attempt per tier.

Each gap below is a real, buildable unit of work against the current
codebase — not a hypothetical. Any of them can be filed via `chump gap
reserve` verbatim and claimed today. Picking real targets (rather than
synthetic toy problems) matters for CREDIBLE-230's goal: the failure map has
to reflect actual repo friction (existing patterns to match, real test
harnesses, real CI gates), not an artificially clean sandbox.

## Selection criteria

- **Self-contained**: no dependency on another in-flight gap, so a tier
  attempt never fails for reasons unrelated to the tier's own capability.
  Full pipeline coverage (claim → edit → commit → PR → CI green → merge)
  requires this — attempts must be able to resolve.
- **Testable in the same PR**: each gap has an obvious, existing test
  location to extend (Rust: a `#[cfg(test)] mod tests` in the same file; TS:
  a matching `*.test.ts` alongside the file). A tier that skips or fakes
  tests should fail the harness's CI-green stage, not pass it.
- **Effort spread**: at least one xs, one s, one m per language, so the
  per-stage failure map (per CREDIBLE-230 AC 4) can show *where* a tier's
  capability drops off as scope grows, not just whether it clears a single
  bar.
- **Language-idiomatic failure surface**: Rust gaps exercise the compiler
  (type errors, borrow errors, `cargo clippy -D warnings`) as a distinct
  failure class from TS gaps, which exercise the type checker plus a JS test
  runner — these are different tool-call shapes, which is exactly the axis
  EFFECTIVE-366 found cheap tiers struggling with (str_replace vs.
  patch_file/run_cli).

## Rust gaps

| # | Gap sketch | File(s) | Effort | Pipeline coverage |
|---|---|---|---|---|
| R1 | Add a `EvalCategory::CodeReview` variant to the eval harness enum, thread it through the existing `match` arms in `check_property` (compiler forces every arm), add one `EvalCase` fixture using it. | `crates/chump-eval-harness/src/eval_harness.rs` | xs | claim → edit (1 file, enum + match arm) → commit → PR → CI (cargo check/clippy/test) → merge |
| R2 | Add a `PublisherAction`-style typed guard in Rust: extend `EvalWeights` with a `regression: f64` field, update `Default`, update every call site that constructs `EvalWeights` with struct-update syntax where missing, add a unit test asserting the new field defaults to 0.0. | `crates/chump-eval-harness/src/eval_harness.rs` (+ 2-3 call sites) | s | claim → edit (2-3 files) → commit → PR → CI (compile errors surface every unmigrated call site — direct test of whether the tier reads compiler output and fixes it, not just the first file) → merge |
| R3 | Add a small `EvalRunResult` aggregation function (e.g. `pass_rate_by_category(results: &[EvalRunResult], cases: &[EvalCase]) -> HashMap<EvalCategory, f64>`) with its own unit tests, wired into whatever reporting path already consumes `EvalRunResult` in the same crate. | `crates/chump-eval-harness/src/eval_harness.rs` | m | claim → edit (new function + `Hash`/`Eq` derive on `EvalCategory` if missing + tests + call-site wiring) → commit → PR → CI (full workspace check/clippy/test, since a derive change on a shared enum can ripple) → merge |

## TypeScript gaps

| # | Gap sketch | File(s) | Effort | Pipeline coverage |
|---|---|---|---|---|
| T1 | Add a new owned platform entry to `PUBLISHER_PLATFORMS` (e.g. a `medium` id with `owned: false`, `allowedActions: FOREIGN_ACTIONS`), add one assertion in the existing test file confirming it's present with the expected actions. | `web/v2/lib/publisher/platforms.ts`, `platforms.test.ts` | xs | claim → edit (1 file + 1 test) → commit → PR → CI (TS type check + vitest/jest run) → merge |
| T2 | Add a pure helper to `queue.ts` (e.g. `nextScheduledSlot(queue, now)` returning the earliest open slot) with full type signatures, plus 2-3 new cases in `queue.test.ts` covering the empty-queue and all-slots-taken edge cases. | `web/v2/lib/publisher/queue.ts`, `queue.test.ts` | s | claim → edit (new exported function, no changes to existing call sites) → commit → PR → CI (type check + test run — tests are the tier's own to write, so a tier that fakes a passing test without real assertions is a distinct, gradeable failure mode) → merge |
| T3 | Add a `draft` validation rule to `style.ts` (e.g. enforce a max-length constraint per platform, reading `PublisherPlatform` from `platforms.ts`), thread it into `draft.ts`'s existing validation path, update `draft.test.ts` and `style.test.ts` with new cases, and confirm no existing test regresses. | `web/v2/lib/publisher/style.ts`, `draft.ts`, `style.test.ts`, `draft.test.ts` | m | claim → edit (cross-file: new rule in one module consumed by another, exercising whether the tier traces the call graph correctly) → commit → PR → CI (type check + full publisher test suite, since cross-file edits are the class most likely to break something outside the edited file) → merge |

## How CREDIBLE-230 should use this list

1. File all 6 as throwaway gaps (or reuse a single scratch branch/worktree
   per attempt) — the point is a controlled, comparable prompt per tier, not
   a shipped feature. Do **not** merge tier-attempt PRs into `main`; discard
   after grading.
2. Run each of the 6 gaps once per model tier under test, using the existing
   claim → edit → commit → PR → CI → merge pipeline exactly as a real worker
   would (per CREDIBLE-230 AC 3 — no shortcut path).
3. Record, per tier per gap: which pipeline stage it reached, and on
   failure, which of the 7-type round taxonomy failure classes it hit
   (tool-call refusal, wrong edit, broken build, failed CI, ship-wall, etc. —
   see `crates/chump-eval-harness/src/eval_harness.rs` for the existing
   round-taxonomy types this should map onto rather than inventing a
   parallel one, per CREDIBLE-230 AC 4).
4. Cost each successful merge (tokens + dollars) per CREDIBLE-230 AC 6 before
   drawing any routing-policy conclusion.

This doc satisfies CREDIBLE-845 alone (the gap *definitions*); the actual
per-tier run and the resulting routing-policy writeup remain scoped to the
parent CREDIBLE-230.
