# Chump 0→1 Onboard Doctrine

> Canonical reference for Chump's external-repo onboarding capability.
> Consumed by: `chump onboard`, the 0→1 audit loop (a later gap), and
> any curator that decides what to merge into an external repo.
>
> Gap: EFFECTIVE-199.  Verify-merge bar: `src/external_verify_merge.rs`.

---

## The Three-Layer Model

Chump's work on an external repo is organized in three layers of increasing
subjectivity.  The layers are ordered: a higher layer is not started until
the lower layer is stable.  The audit (a later gap) produces a doctrine-tagged
mission portfolio seeded from this model; the loop runs missions in L1→L2→L3
order.

### L1 — Foundation

**Objective, always applies, bootstraps verifiability.**

Before anything else is possible, the repo must be in a state where Chump can
run it, test it, and trust that CI catches regressions.  L1 is entirely
objective — every criterion either passes or fails, no judgment required.

L1 gates:

- Tests run and pass in CI.
- Clean build from a fresh checkout (no manual setup steps, no undeclared deps).
- CI gates every PR (no open PR merges without a green CI signal).
- No leaked secrets (no credentials, tokens, or private keys in history or
  current HEAD).
- All declared dependencies resolve (package manager lock file present and
  installable).

The standard L1 mission set is defined in `src/standard_missions.rs` and is
auto-injected by the 0→1 audit into the foundation queue for any onboarded
repo.  See "How the Loop Uses This" below.

### L2 — Fulfillment

**Grounded: make the product do what it claims.**

Once the foundation is stable, L2 work closes the gap between what the README
or docs say and what the code actually does.  A documented feature with no
working, tested implementation is a defect — L2 treats it as one.

L2 work is grounded in concrete evidence: a README claim, a docs page, an
issue, a TODO with a "planned" tag.  Every L2 gap must cite a specific source
(per the evidence discipline in `chump onboard`'s agentic scout).

### L3 — Realization

**Subjective: develop latent ideas within the repo's own identity.**

Once the product does what it claims, L3 work develops its *latent potential*
— ideas the codebase is clearly reaching toward, user needs that fall naturally
out of its domain, improvements that a skilled maintainer would recognize as
"obviously belonging here."  L3 never imposes a foreign agenda.

L3 work is the most speculative and must be the most reversible.  A speculative
L3 feature that can only be removed by reverting five entangled commits is an
L3 violation.  Additive, feature-flagged, or plugin-style changes are preferred.

---

## The Eight Principles

### 1. Foundation before features

No L2 or L3 work is started while L1 gaps are open.  A repo with a broken CI
pipeline cannot reliably accept improvements — every merge is a gamble.
Stabilizing the foundation is not overhead; it is the prerequisite for
everything else.

### 2. Truth-in-advertising

A README claim with no working, tested implementation is a bug, not a gap in
coverage.  L2 treats undocumented absence as acceptable and documented absence
as a defect.  Chump does not add features before it delivers what has already
been promised.

### 3. Realize, don't impose

L3 work develops ideas the repo is already expressing — the natural next step
in its own trajectory.  Chump does not graft its own architecture, naming
conventions, or opinions onto a foreign codebase.  When in doubt: if the
maintainer would not recognize the change as "obviously ours," it does not
belong.

### 4. Value must be legible

Every merge must carry a provable benefit: a test that was failing and now
passes, a CI check that was absent and is now required, a documented feature
that is now implemented and tested.  "This is cleaner" or "this follows better
practices" is not a mergeable reason on its own.  The verify-merge bar
(`src/external_verify_merge.rs`) enforces this mechanically.

### 5. Every merge is earned

All merges into an external repo — regardless of size — go through the
`chump external verify-merge` bar.  The three gates are: repo CI green, an
anti-cosmetic test gate (a test that fails on base and passes on head), and
no regression on the existing suite.  A PR with no changed test files is held
as cosmetic.  A PR whose test passes on both base and head proves nothing and
is held as unproven.

### 6. Coherence over count

A batch of 10–20 PRs is an arc — each PR anticipates the next, the set tells a
coherent story from foundation to feature.  Disjoint changes that happen to
land in the same window are not a batch; they are noise.  The 0→1 audit
produces a mission portfolio precisely so that related gaps are planned as an
arc before any single one is executed.

### 7. Reversible ambition

The more speculative the work, the more reversible it must be.  L1 changes
(adding a CI file, a `.gitignore` rule) are inherently reversible.  L2 changes
(implementing a claimed feature) may touch core logic but must not entangle
unrelated code paths.  L3 changes must be additive where possible: a new
module, a new flag, a new test class — not a rewrite of existing behavior.  If
a speculative change cannot be reverted without cascading impact, it is too
ambitious for autonomous merge.

### 8. Respect maintainer intent where it exists

When a repo contains a `CONTRIBUTING.md`, `AGENTS.md`, `CLAUDE.md`, or
explicit style guide, those documents define the lane.  Chump's additions
should be indistinguishable from thoughtful human contributions that follow the
same guide.  Where no explicit intent exists, the repo's existing conventions
(commit message style, test structure, module layout) are the implicit guide.

---

## How the Loop Uses This

The 0→1 onboard loop operates as follows:

1. **Audit** — `chump onboard --apply` (or the scheduled overnight runner)
   scans the repo and runs the 0→1 audit.  The audit reads
   `src/standard_missions.rs` to seed the L1 foundation queue with the five
   standard missions.  It then uses the agentic scout to discover L2 claim
   gaps (README promises without tests) and L3 realization theses (latent
   ideas grounded in the repo's own signals).  Each proposed gap is tagged
   with its doctrine layer (`layer: L1`, `layer: L2`, or `layer: L3`).

2. **Portfolio** — The audit produces a doctrine-tagged mission portfolio:
   a `Mission` (see `docs/design/MISSION_TYPES.md`) whose objectives are
   ordered L1 → L2 → L3.  L1 objectives are set to `sequence: 0`, L2 to
   `sequence: 1`, L3 to `sequence: 2`; within each layer, gaps are ordered
   by confidence descending.

3. **Execution** — The loop picks gaps in mission order.  L2 objectives are
   not started until all L1 objectives are `Completed`.  L3 objectives are
   not started until all L2 objectives are `Completed`.

4. **Verify-merge gate** — Every completed gap goes through
   `chump external verify-merge` before the PR is opened.  The three gates
   (CI green, anti-cosmetic test, no regression) enforce Principle 5 for
   every layer.  An L1 gap that only adds a CI config file must still pass
   the anti-cosmetic gate by including or modifying a test that demonstrates
   the CI config is exercised.

5. **Loop continues** — After each merge, the loop re-evaluates the
   portfolio.  New L2 signals discovered after an L1 fix (e.g., a previously
   hidden test failure now visible) are added to the portfolio at `sequence: 1`.
   The loop terminates when the portfolio is empty or the operator halts it.
