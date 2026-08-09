---
doc_tag: decision-record
owner_gap: CREDIBLE-273
last_audited: 2026-08-09
---

# Factory yield — measure rework, not speed

**Decision record, 2026-08-09.** Written with the operator, who thinks in
defect-rate terms. This is not a Six Sigma programme; it borrows one idea —
*count the rework, then classify it before acting* — and applies it to the
gap→PR→merge pipeline.

## The question that started it

> *"How would we do this at scale, more efficiently? It's all about improving
> the factory's outputs. Fast and quality. Zero output is not acceptable."*

The tempting answer was "make CI faster." The measurement says CI duration is
not the constraint.

## What was measured

Two samples, and the difference between them is the first finding.

**Sample A — one session's seven PRs, hand-counted:**

| PR | CI runs | failed | outcome |
|---|---|---|---|
| #3524 DOC-089 (doc-only) | **1** | 0 | merged |
| #3551 RESILIENT-266 | 2 | 1 | merged |
| #3544 RESILIENT-263 | 6 | 6 | merged |
| #3525 RESILIENT-248 | 7 | 5 | merged |
| #3510 CREDIBLE-215 | 9 | 9 | **destroyed** |
| #3499 INFRA-1965 | 11 | 11 | **destroyed** |
| #3509 EFFECTIVE-396 | 15 | 13 | merged |

51 runs / 7 PRs. First-pass yield **1/7 ≈ 14%**. Two PRs burned 20 runs and
shipped nothing.

**Sample B — fleet-wide, 2 days, via the script this record ships:**

```
ALL    PRs=14  first-pass=7/14 (50%)  runs=38  rework=2.7x  destroyed=3
code   PRs=12  first-pass=5/12 (41%)  runs=36  rework=3.0x  destroyed=2
doc    PRs=2   first-pass=2/2 (100%)  runs=2   rework=1.0x  destroyed=1
```

**The instrument refuted the anecdote that motivated it, within a minute of
existing.** Sample A was 14% because it was the PRs someone was *fighting* —
a selection bias invisible from inside the fight. The real code number is 41%.
Still poor. Not catastrophic. That gap between felt and measured is exactly
what the metric is for, and it is the argument for shipping the script rather
than the story.

## The lever is in the failure MIX, not the failure count

Classifying Sample A's ~45 failures:

| Class | ~count | Meaning |
|---|---|---|
| **Real defects in the change** | ~2 | what CI is FOR |
| **Obligations discovered late** | ~10 | parity mirror ×4, docs-delta ×2, install-manifest, stale base ×2 |
| **False signals** | ~11 | CREDIBLE-175 `cargo test` env race; the `proof_of_merge` flake ×5 |
| **Scope-blind detectors** | ~5 | tests pinned to `src/main.rs`, broken by a legitimate refactor |

**Under 5% of CI failures were the thing CI exists to catch.**

That single line reframes the whole problem. The factory is not failing to catch
bad work; it is spending its capacity on process obligations and on lies.

It also answers a strategy question that was live at the time — whether a
supporting agent should *build* work and hand it to another agent to QA. It
would not have helped: **almost none of the rework was authorship error.** It
was rules discovered late and signals that were false. Handing over finished
code inherits both, minus the context to recognise them.

## Crawl / walk / run

**CRAWL — instrument it. No new plumbing.**
`scripts/ops/first-pass-yield.sh` computes FPY, rework multiplier and destroyed
count from `gh run list`, split by doc vs code. Run it weekly. Doc-only already
runs at 100% FPY with a 1.0× multiplier; code runs at 41% and 3.0×. That
contrast is a finding on its own and makes later claims arguable instead of
asserted.

**WALK — shift the top three obligations left.**
`preflight-parity`, `docs-delta` and `install-manifest` each fail in CI after
~12 minutes and could fail in pre-commit in about a second. That is ~10 of
Sample A's failures converted from round trips to instant feedback. DOC-096
covers the parity half; extend it to the other two.

**RUN — kill the false signals.**
These *destroy* output rather than delay it, which is the "zero output is not
acceptable" case stated precisely:

- the `proof_of_merge` flake did not slow PR #3510, it **killed** it —
  CREDIBLE-251
- RESILIENT-250's deadlock made #3499 **structurally unmergeable** regardless of
  its quality

Two named gaps, not a culture problem.

## The blind spot — and it is not small

Yield thinking optimises the line you already have. It can only see things that
**fail**. The largest wins of the same session were invisible to it:

- **mold** was installed and never wired to `RUSTFLAGS` — a fast linker sitting
  unused (EFFECTIVE-396)
- **operator-recall** sat `enabled = true` with zero processes since 2026-05-08;
  nobody noticed for three months
- a clean merge nearly **deleted `chump gap write-ac`**, and git reported success

Every one of those is a **zero-defect state** by any process metric, because
nothing was failing. A yield metric cannot see an instrument that quietly
stopped reporting.

So: keep two lenses. Yield for the line, and periodic adversarial sweeps for the
instruments — "what is green because it stopped looking?" The session that
produced this record was the second kind, and it found more value than the first
kind would have.

## What this record commits to

1. `first-pass-yield.sh` runs weekly; the number is compared, not re-derived.
2. Failures get **classified** before any "reduce failures" work is scheduled.
3. Destroyed PRs are tracked separately from slow ones — they are a different
   defect with different causes (CREDIBLE-251, RESILIENT-250).
4. The blind spot is named in the metric's own output, so a green number is
   never mistaken for a healthy factory.
