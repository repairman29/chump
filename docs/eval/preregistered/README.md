# Preregistration directory — how to use

> **What this is.** One markdown file per eval or research gap that involves
> live data collection, locked **before** the first trial runs. Each file
> follows [`TEMPLATE.md`](TEMPLATE.md) and captures the hypothesis,
> analysis plan, stopping rule, and expected effect size.
>
> **Why.** Every EVAL-NNN and RESEARCH-NNN finding to date was analyzed
> *after* the data came in. That inverts the scientific contract: you can
> always find a pattern in the data, but only preregistered hypotheses
> protect against motivated analysis. See
> [`docs/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md)
> §3 for the full motivation.

## The contract (RESEARCH-019)

For any new EVAL-\* or RESEARCH-\* gap that collects fresh trial data:

1. **Author a preregistration before the first live trial.** Copy
   [`TEMPLATE.md`](TEMPLATE.md) to `<GAP-ID>.md`, fill every field, and
   commit it to `main` (or your PR branch) **before** any JSONL lands in
   `logs/ab/`.
2. **Do not edit the preregistered fields after data collection begins.**
   If you need to change something (fixture bug, judge swap, early stop),
   add a **Deviations** entry at the bottom of the file with a timestamp
   and reason. Do **not** silently edit the original fields.
3. **Cite the preregistration in your gap-closure commit.** The gap's
   `closed_finding` field should link to this file.

Pre-commit guard (future: part of RESEARCH-019 infra completion — **not
yet shipped**): `scripts/git-hooks/pre-commit` will reject status-flip-to-done
commits on an EVAL-\* or RESEARCH-\* gap if no `docs/eval/preregistered/<gap>.md`
is committed to HEAD before the first trial JSONL file. Bypass:
`CHUMP_PREREG_CHECK=0` with an explicit justification in the commit
message.

## What belongs here vs. not

**In scope** — gaps that collect new trial data (A/B sweeps, calibration
runs, ablation studies, human grading). Examples: RESEARCH-018
(length-matched control), RESEARCH-021 (tier-dependence 4-family),
EVAL-043 (full ablation suite).

**Out of scope** — gaps that don't collect new data, i.e., doc-only
gaps, infrastructure gaps, tooling gaps, post-hoc re-analyses of
existing JSONLs. Examples: RESEARCH-022 (reference analysis applied to
existing data — no preregistration needed, but cite the JSONL range
being analyzed), INFRA-\* gaps generally.

## Relationship to `docs/eval/EVAL-NNN-*.md` result docs

The **preregistration** (this directory) locks the hypothesis and
analysis plan before the sweep. The **result document** (at
`docs/eval/EVAL-NNN-*.md`) reports what happened after. These are
separate files and should remain separate. When the result doc is
authored, it must link back to the preregistration and explicitly note
any deviations.

## One-liner: how to start a new preregistration

```bash
cp docs/eval/preregistered/TEMPLATE.md docs/eval/preregistered/RESEARCH-028.md
# fill every field; do not leave any placeholders
git add docs/eval/preregistered/RESEARCH-028.md
git commit -m "prereg(RESEARCH-028): <one-line hypothesis>"
# THEN run your sweep
```

## Frequently asked questions

**Q: What if my sweep produces a signal I didn't predict?**
A: Report the preregistered analysis first, then add a clearly-labeled
"Exploratory analysis" section in the result doc. Both have value; they
have different credibility levels.

**Q: What if I find a bug in the harness mid-sweep?**
A: Stop the sweep. Add a Deviations entry to the preregistration. Fix
the bug. Restart from zero (do not splice the pre-bug and post-bug data
unless you can prove the bug didn't affect prior trials).

**Q: Can I preregister a sweep I've already started?**
A: Technically yes, but mark it clearly at the top: "Retrospective
preregistration — data collection began at commit SHA, preregistration
authored at commit SHA." Readers should weight the finding lower. Prefer
to design *new* sweeps with proper preregistration going forward.

**Q: What's the minimum quality bar?**
A: Every field in `TEMPLATE.md` must be non-placeholder. The hypothesis
must be falsifiable. The primary metric must be specified to the point
that two different analysts computing it would get the same number.
