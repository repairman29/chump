# Gate authoring — the recipe

**Why this doc exists.** Landing one anti-bloat gate (MISSION-045, the P0/P1
outcome gate) took three full CI rounds (~20 min each) because I re-derived,
live, every constraint the fleet already imposes on a new enforcement gate.
None of it was novel — it was all knowable. This is the checklist so the next
gate-author (agent or human) inherits the lesson instead of re-earning it.

A "gate" here = any code path that **refuses** an action (`std::process::exit(1)`,
a failing CI check, a pre-commit/pre-push block) to enforce a rule.

---

## The six things a new gate needs (in order)

### 1. A test that proves it BITES — before anything else
A keystone gate shipped with **zero** coverage is the default failure mode
(MISSION-045 had none until forced). "Green" never means "covered" here.
Write `scripts/ci/test-<gate>.sh` that asserts, at minimum:
- the gate **blocks** the disallowed action (exit non-zero),
- the gate **allows** the compliant action (exit zero),
- each **escape hatch** (flag/skip) works **and** is audited,
- the **permissionless** case (if any) still passes.

See `scripts/ci/test-outcome-gate.sh` for the shape (6 cases, ~2s, self-builds).

### 2. An empty-fixture skip — so you don't break every seeding test
A gate that fires on `gap reserve` / `gap ship` / etc. will break **every CI
fixture that seeds that object**, because synthetic DBs don't satisfy the new
precondition. Do **not** whack-a-mole a bypass flag into each test.

The durable pattern: **skip the gate when the thing it requires cannot exist.**
The MISSION-045 gate requires a P0/P1 gap to trace to an *outcome*; a fresh
fixture DB has **zero** outcomes, so the requirement is vacuous — skip it:

```rust
let has_outcomes = store.list_outcomes().map(|o| !o.is_empty()).unwrap_or(false);
if is_p01 && !traced && !bypass && has_outcomes { /* refuse */ }
```

One code change, zero test edits, zero bypass vars — and the gate stays fully
live in production (the real repo always has outcomes). Prefer a *vacuous-skip*
over an env-var bypass every time.

### 3. No new bypass env var (EFFECTIVE-094 debt ceiling)
`scripts/ci/test-no-new-bypass-env-vars.sh` counts bypass/skip vars against a
ceiling. Adding one usually trips it. Use an **audited CLI flag**
(`--no-<gate>-required`) that emits an ambient event, not an env var. If the
vacuous-skip (step 2) covers fixtures, you often need no bypass at all.

### 4. Register any escape hatch's ambient event
If the bypass flag emits `kind=<gate>_bypassed`, add that kind to
`scripts/ci/event-registry-reserved.txt` (INFRA-1237/1287 coverage gate), and
document any env var in `.env.example` (DOC-026).

### 5. Mirror the CI step in preflight (INFRA-1867 parity)
Every CI gate must have a local-preflight mirror or be classified Tier-D /
allowlisted, or `preflight-vs-CI parity` fails. Add the script to the
whitelist in `src/preflight.rs` (`discover_test_scripts`).

**Sharp edge (cost me 3 iterations):** the parity parser reads **only the first
line** of a multi-line `run:` block
(`scripts/ci/test-preflight-ci-parity.sh`, `run_cmd = run_lines[0]`; see
CREDIBLE-169). If your first line is `cargo build …`, it never sees the
`bash scripts/ci/test-<gate>.sh` on line 2. Make the invocation a **single-line
`run:`** and let the test self-build its binary.

### 6. Same-commit test updates for behavior changes
If the gate **changes** existing behavior (MISSION-045 also turned the curator's
`balance_restock` from "file a gap" into "signal-only"), the tests asserting the
old behavior must be updated **in the same commit** — asserting the *new* correct
behavior, not deleted. Green-by-deletion is not covered.

---

## Blast-radius first (the meta-lesson)

The reason this took three CI rounds: a single behavior change had a blast
radius I couldn't enumerate up front, so failures surfaced one CI run at a time.
Before pushing a gate:

- **Grep for every fixture that touches the object** (`grep -rl 'gap reserve' scripts/ci`),
  run them locally against your branch binary, fix them all in one pass.
- Prefer the **vacuous-skip** (step 2) so the blast radius collapses to ~zero.
- Filed follow-ups to make this systemic: **EFFECTIVE-318** (`preflight --full`
  == CI shards locally), **EFFECTIVE-319** (`chump impact <diff>` blast-radius
  preview), **EFFECTIVE-320** (this recipe + a scaffold + a "new enforcement
  path → must-have gate test" check). Pick them up to delete this friction.

Receipts: MISSION-045 session 2026-07-27 · CREDIBLE-169 · EFFECTIVE-318/319/320 ·
RESILIENT-201.
