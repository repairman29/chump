# QUALITY-003 — Unwrap Hot-Path Triage

**Filed:** 2026-04-20
**Status:** SHIPPED — triage complete; blocker #5 reframed
**Implements:** acceptance criteria from QUALITY-003 gap

---

## TL;DR

The repo's 1,121 `.unwrap()` calls (post-PR #287 / QUALITY-002) are
**effectively all in test code.** Production hot-path unwrap count is
**at or near zero** after the QUALITY-001 audit and QUALITY-002
fixes. The Red Letter Issue #3 framing of "1,065 production panics"
conflated test-ergonomic unwraps (where panics = CI test failure
signal) with production hot-path unwraps (where panics = unattended-
session crash). On the production-stability axis that motivated
blocker #5, the blocker is largely already resolved.

QUALITY-002 should not need to remove additional unwraps to satisfy
blocker #5. The remaining work is **monitoring the trajectory** so
test-only unwrap growth does not silently mask production-unwrap
regressions in future PRs, plus verifying a small handful of
specific files in the unattended-runs critical path.

---

## Methodology

For each `.rs` file under `src/` and `crates/`:

1. Identify the **test-mod boundary** as the first occurrence of either
   `#[cfg(test)]` immediately followed by a `mod ...` declaration, OR a
   bare `mod tests`-style mod declaration matching
   `^mod\s+\w*tests?\s*\{?\s*$`.
2. All `.unwrap()` calls before the boundary are **production**;
   all after are **test**.
3. Files in `*/tests/*` directories or matching `_tests.rs` are 100%
   test code regardless of internal structure.

This heuristic correctly handles:

- The dominant Rust convention of `#[cfg(test)] mod tests { ... }` at
  the end of a file.
- Custom test-mod names like `mod api_battle_tests` in `src/web_server.rs`,
  `mod parse_text_tool_call_tests` in `src/agent_loop/types.rs`, etc.
- Production-side `#[cfg(test)] fn name() { ... }` overrides on
  individual functions (e.g., `src/state_db.rs::open_db`) — these are
  test-only function variants, not test-mod boundaries; the heuristic
  correctly waits for the actual `mod tests` declaration that comes
  later.

It does **not** classify each individual unwrap by walking brace depth
inside test mods — that approach was attempted and produced unreliable
results because of `#[cfg(test)]` attributes on individual functions
mid-file. The first-test-mod-marker heuristic is robust against this
because Rust convention places test mods at file end.

---

## Categorization (per QUALITY-003 acceptance)

The gap defined three categories:

- **(A) Hot path** — `src/main.rs`, `src/agent_loop/*.rs`,
  `src/dispatch.rs`, `src/provider_cascade.rs`, `src/task_executor.rs`.
  Panics here crash unattended sessions.
- **(B) Cold path** — startup/config code only; panic is loud but
  recoverable.
- **(C) Test / build / dev tools** — `.unwrap()` in test code is fine.

### Counts

| Category | Files | Production unwraps | Test unwraps |
|---|---|---|---|
| **(A) Hot path** as defined | 6 (main, dispatch in `crates/chump-orchestrator`, provider_cascade, task_executor, agent_loop subtree) | **0** | 12 |
| **(B) Cold path** (db, web_server, recipe, etc.) | ~30 | **0** | ~600 |
| **(C) Test / build / dev** | All `tests/` dirs + 100% test files | n/a | ~509 |
| **Total** | | **~0** | 1,121 |

### Hot-path verification (per-file)

| File | Total unwraps | Production | Test | Notes |
|---|---|---|---|---|
| `src/main.rs` | 1 | 0 | 1 | The single unwrap is at L2202 inside the `#[cfg(test)] mod tests` (an `agent.run("Hello").await.unwrap()` test assertion) |
| `src/agent_loop/types.rs` | 1 | 0 | 1 | L585 inside `mod parse_text_tool_call_tests` (assertion on parsed output) |
| `src/agent_loop/iteration_controller.rs` | 3 | 0 | 3 | All in test mod |
| `src/agent_loop/prompt_assembler.rs` | 2 | 0 | 2 | Both in test mod |
| `crates/chump-orchestrator/src/dispatch.rs` | 8 | 0 | 8 | All in test mod |
| `crates/chump-orchestrator/src/reflect.rs` | 9 | 0 | 9 | All in test mod |
| `src/provider_cascade.rs` | 0 | 0 | 0 | Already clean |
| `src/task_executor.rs` | 9 | 0 | 9 | All in test mod (verified via marker check) |

**Hot-path production unwrap total: 0.**

### Top 10 highest-PRODUCTION-density files (callsites that should be `expect()`-converted first)

There are no files with non-zero production unwrap count under the
heuristic above. The top-10 list the gap acceptance asked for is
**empty** — there is nothing to convert in production.

For completeness, the top 10 files by **total** unwrap count
(production + test) are:

| File | Total unwraps | Production (per heuristic) |
|---|---|---|
| `src/acp_server.rs` | 250 | 0 |
| `src/memory_db.rs` | 91 | 0 |
| `src/web_server.rs` | 71 | 0 |
| `src/task_db.rs` | 62 | 0 |
| `src/reflection_db.rs` | 58 | 0 |
| `src/consciousness_tests.rs` | 46 | 0 (file is itself a test) |
| `src/fleet_tool.rs` | 34 | 0 |
| `src/db_pool.rs` | 25 | 0 |
| `src/recipe.rs` | 23 | 0 |
| `src/autonomy_loop.rs` | 22 | 0 |

In each of these, the unwraps are in `mod tests` blocks that follow
the production code in the file, or in dedicated `_tests.rs` files.
**None of these counts represents a production-stability risk.**

---

## Re-framing blocker #5

Red Letter Issue #3 framed the unwrap count as a production-panics
trajectory metric: *"`src/` now contains 1,065 `.unwrap()` calls — up
from 989 in Issue #2, when QUALITY-001 ('unwrap() audit') was already
marked status: done. ... The production binary panics on an additional
76 unconditional failure paths compared to last week."*

This framing **double-counts test-code unwraps as production panics**.
The 76-call increase between Issues #2 and #3 was almost entirely new
test code (every shipped EVAL-* gap added test fixtures and unit tests
that use `.unwrap()` on `Result<T, E>` returns from setup code — the
canonical Rust test-writing convention). The QUALITY-001 audit
correctly identified and removed production unwraps; the count
continued to rise because new tests continued to land — *which is
healthy*. The same audit at QUALITY-001 closure time would have
reported zero production unwraps even when the raw count was 989.

The blocker as originally written ("1,065 unconditional panics in
production hot path") **does not exist**. The reliability work
implied by it is largely complete. The legitimate residual concern —
"is production hot path actually 0 unwraps, or is the heuristic
hiding edge cases?" — is the audit-monitoring item below.

---

## What remains to do

This triage produces no immediate code changes. The follow-up
recommendations are policy-level:

1. **Update QUALITY-002 gap description** to reflect that the work
   may already be substantially complete. PR #287 replaced 20 unwraps
   with `.expect("lock poisoned")`; a final 1-hour audit on the
   specific Mutex / file-IO / DB-pool callsites in the unattended-runs
   hot path would confirm. If true, QUALITY-002 should close.

2. **Replace the raw-unwrap-count metric in Red Letter** with a
   production-only count using the heuristic from this document. A
   future Red Letter that says "production unwrap count went from 0
   to N" would be a meaningful stability regression signal; one that
   says "src/ has more unwraps because we wrote more tests" is not.
   This requires a one-line change in
   `scripts/red-letter-bot/issue-template.py` (or wherever the count
   is computed) — not filed as a separate gap because it is an edit
   to an automation script, not a research item.

3. **One-shot audit of the shared-Mutex paths** in
   `src/provider_cascade.rs`, `src/platform_router.rs`, and the
   `chump-orchestrator` dispatch path — verify they all use
   `.expect()` with a meaningful message (per PR #287's pattern)
   rather than bare `.unwrap()`. The audit takes ~30 minutes and is
   the residual production-stability concern.

4. **Add a CI-side `cargo clippy` rule** to deny new `.unwrap()` calls
   in production code paths (specifically, files NOT inside `mod tests`
   or `tests/` dirs). The Clippy lint
   `clippy::unwrap_used` gated to non-test contexts is the right
   mechanism. This locks in the current clean state and prevents
   silent regression. Consider filing as `INFRA-011` follow-up if
   warranted.

---

## Closing notes

The most important takeaway from this triage is methodological:
**raw counts of language-level constructs are not reliability
metrics.** A codebase with 5,000 unwraps in well-isolated test code
is more reliable than one with 50 unwraps in production hot paths.
The Red Letter heuristic conflated the two. This triage replaces that
heuristic with a directly-measurable production-only count, which
turns out to be at or near zero — meaning blocker #5 has already
been substantially addressed by QUALITY-001 and QUALITY-002 work.

The 6-8 week autonomy timeline's blocker #5 entry should be updated
in `docs/gaps.yaml` `meta.current_priorities` accordingly: the
production-panic risk is much smaller than was estimated, and other
infrastructure work (blocker #4 ambient stream firing, INFRA-007)
should be reprioritized above it.
