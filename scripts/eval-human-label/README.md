# EVAL-010 — Human-labeled fixture subset

Tooling to break the **author-grades-author + same-model-judges-agent** circularity in the cognitive-layer A/B fixtures.

## Why this exists

The cloud A/B sweep (PR #44) and harness fix (PR #47) both rely on `claude-sonnet-4-5` as the LLM judge for `claude-haiku-4-5` and `claude-sonnet-4-5` outputs. Both the rubric and the judge come from the same model family. We have no ground truth to know whether the judge's verdicts are well-calibrated.

EVAL-010 produces that ground truth from a small (~12 task pair, ~24 trial) subset.

## Workflow

### 1. Extract a labeling file

```bash
python3 scripts/eval-human-label/extract-subset.py --per-fixture 5
```

This walks the most-recent cloud A/B `*.jsonl` files for each fixture (preferring system-role / post-PR-#47 runs, falling back to whatever exists), picks 5 tasks per fixture, and emits `docs/eval/EVAL-010-labels.md`.

The picker prioritizes **task pairs where modes A and B disagree** (most informative for ground truth) plus a few both-pass and both-fail for calibration.

### 2. Grade the file

Open `docs/eval/EVAL-010-labels.md`. Each task has:
- the prompt
- mode A response (lessons in system role)  + the LLM judge's score
- mode B response (no lessons) + the LLM judge's score
- two checkbox slots: `- Human grade A: [ ] PASS` and `- Human grade B: [ ] PASS`

Replace `[ ]` with `[x]` for each response that satisfies the prompt. Leave blank if it doesn't. **Don't peek at the LLM scores while grading** — bias.

Grading guideline:
- Verbose-but-correct = pass
- Confidently wrong = fail
- Hedging-but-correct = pass
- Refusing-when-should-help = fail

Estimated time: ~90s per task pair → 12 pairs ≈ 18 minutes.

### 3. Score the labels

```bash
python3 scripts/eval-human-label/score-with-labels.py
```

Prints per-fixture human-judge delta (A − B), LLM-judge delta on the same subset, and the gap between them. If any fixture's gap exceeds **0.05**, the LLM-as-judge methodology should be deprecated for that fixture class until calibrated against a larger labeled set.

## Output

After grading, append a section to `docs/CONSCIOUSNESS_AB_RESULTS.md` with the comparison table. This unblocks COG-014 (task-specific lessons) — the next experiment that needs trustworthy A/B measurement to validate.
