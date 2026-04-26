# RESEARCH-026 — Observer-effect / evaluation-framing (result shell)

**Gap:** `RESEARCH-026` in `docs/gaps.yaml`  
**Preregistration:** [`preregistered/RESEARCH-026.md`](preregistered/RESEARCH-026.md)  
**Pilot / rewrite rules:** [`RESEARCH-026-naturalization-pilot.md`](RESEARCH-026-naturalization-pilot.md)

**Harness shipped:** [PR #400](https://github.com/repairman29/chump/pull/400) on `main` (2026-04-21).

## Operating stance (as of 2026-04-21)

- **`RESEARCH-026` stays `open`** in `docs/gaps.yaml` until the preregistered
  full cloud sweep and Wilson write-up meet acceptance (then `closed_commit`).
- **This memo and the FINDINGS row stay “pending full sweep”** — no pretending
  the observer-effect question is empirically closed without n=50/cell × two
  tiers.
- **Ordinary product and infra work proceeds without blocking on that expense.**
  Harness, CI preflight, human pilot gate, and harness smoke are the **minimum
  shipped bar for “safe to keep building.”**
- **Schedule the paid sweep** (~\$15–\$20) when you enter a **paper or external
  credibility sprint**, not because the internal queue needs the number for the
  next feature.

## Status


| Milestone                                                                                              | State                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 50-task casual fixture (`reflection_tasks_casual_v1.json`)                                             | **Done** (`naturalize-fixture.py`)                                                                                                                                                      |
| 50-task formal fixture paired to same IDs/order                                                        | **Done** (`reflection_tasks_formal_paired_v1.json` via `sync-reflection-paired-formal.py`)                                                                                              |
| Harness wiring (`run-observer-effect-ab.sh` + `run-cloud-v2.py --n-per-cell --out-dir` + CI preflight) | **Done** ([PR #400](https://github.com/repairman29/chump/pull/400))                                                                                                                     |
| Human validation gate (≥8/10 pilot rewrites)                                                           | **Done** (10/10 — [`RESEARCH-026-naturalization-pilot.md`](RESEARCH-026-naturalization-pilot.md) § validation gate; agent pre-pass + **human sign-off Jeff Adkins 2026-04-21**) |
| Cloud sweep n=50/cell × 2 framings × 2 tiers (=400 trials in gap accounting)                           | **In progress** — harness **smoke** passed 2026-04-21 (see § Harness smoke); **full** preregistered sweep still to run (~\$15–\$20)                                                                 |
| Wilson / paired analysis → `docs/audits/FINDINGS.md`                                                          | **Pending** for n=50 tiers; smoke pairing recorded below (not citable as the preregistered result)                                                                                      |


This file becomes the **canonical result memo** once the sweep finishes: paste
per-tier summaries, judge panel, and the §9 decision (H1 vs H0).

## Harness smoke (2026-04-21)

**Not** the preregistered measurement (that is n=50/cell × haiku + sonnet). This
is a cheap end-to-end check after the human validation gate: from repo root,
`scripts/ab-harness/run-observer-effect-ab.sh --smoke` (pilot casual fixture,
`--n-per-cell 2`, **haiku** only). Artifacts are under `logs/` (gitignored
locally): `research-026-haiku-formal-1776793053-1776793053.jsonl` and
`research-026-haiku-casual-1776793053-1776793068.jsonl`.

Cell **A** (lessons on) framing comparison — `analyze-observer-effect.py`:

```
Paired tasks: n=2  cell=A
  Formal:  correct_rate=1.000  Wilson95=(0.342,1.000)  k=2/2
  Casual:  correct_rate=1.000  Wilson95=(0.342,1.000)  k=2/2
  Δ (formal − casual): +0.000
  Confusion: both=2 formal-only=0 casual-only=0 neither=0
```

Wilson intervals are wide at n=2; do not treat this as evidence for or against H1.

## One-command sweep (after validation gate)

From repo root (requires `ANTHROPIC_API_KEY` and judge access as for other
`run-cloud-v2.py` sweeps):

```bash
scripts/ab-harness/run-observer-effect-ab.sh \
  --casual-fixture scripts/ab-harness/fixtures/reflection_tasks_casual_v1.json \
  --n-per-cell 50 \
  --tiers haiku sonnet
```

Formal fixture defaults to `reflection_tasks_formal_paired_v1.json` (paired to
the casual file). Override with `--formal-fixture` only if you know the IDs
still match.

Smoke / harness check (cheap):

```bash
scripts/ab-harness/run-observer-effect-ab.sh --smoke
```

## Analysis (after JSONLs land)

For each tier, pick the matching pair of JSONLs (`research-026-<tier>-formal-*`
vs `research-026-<tier>-casual-*` timestamps from the same run), then:

```bash
python3.12 scripts/ab-harness/analyze-observer-effect.py \
  --formal-jsonl logs/ab/research-026-haiku-formal-<ts>.jsonl \
  --casual-jsonl logs/ab/research-026-haiku-casual-<ts>.jsonl \
  --cell A
```

**Interpretation note:** `run-cloud-v2.py` still runs an internal **lessons A
vs B** ablation per fixture. For framing isolation, the preregistered primary
comparison holds **lessons constant** by comparing **cell A** (lessons on)
between the formal pass and the casual pass at the same tier, paired by
`task_id`. Use `--cell B` only for a secondary “lessons-off framing” probe.

## Regenerate paired formal after casual edits

Whenever `reflection_tasks_casual_v1.json` is regenerated:

```bash
python3.12 scripts/ab-harness/sync-reflection-paired-formal.py
```

## Decision rule (from prereg §9)

- **|Δ| > 0.05** (formal vs casual, per tier, with CI excluding zero): document
observer-effect correction requirement for Paper 1.
- **Otherwise:** record as validation that casual naturalization did not move
correctness enough to threaten published deltas.

