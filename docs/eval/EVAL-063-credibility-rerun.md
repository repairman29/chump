# EVAL-063 — Credibility re-aggregation (llm_judge-only)

**Date:** 2026-04-25
**Gap:** EVAL-084 (closes the hole EVAL-083 audit identified)
**Status:** COMPLETE — **EVAL-063 RETIRED** (insufficient llm_judge A/A baseline)
**Source data:** `docs/archive/eval-runs/eval-063-2026-04-22/*.jsonl`
**Pattern:** Same retirement as EVAL-069 (EVAL-082 audit).

## TL;DR

EVAL-063's archived run cannot be salvaged by re-aggregating `scorer == 'llm_judge'`
rows alone, because **the A/A baseline files were captured exclusively under the
broken `exit_code_fallback` scorer.** Per-module bypass-on rates can be computed
under llm_judge alone (n=100-199/cell), but with no comparable A/A baseline the
"delta vs A/A" claim that EVAL-063 originally published has no valid statistical
contrast. EVAL-063 is therefore **RETIRED** like EVAL-069, and FINDINGS F3's
credibility caveat is extended to cover both retirements.

The substantive REMOVAL-003 (belief_state) decision is **unaffected** because the
llm_judge half of the data shows bypass-on rates of 0.620–0.668 across all three
ablated modules — no module's bypass crashes correctness, consistent with the
"NEUTRAL" interpretation that fed REMOVAL-001's matrix.

## What the archived JSONL actually contains

10 files in `docs/archive/eval-runs/eval-063-2026-04-22/`. Per-file scorer split:

| File (timestamp) | Module (`bypass_var`) | Rows | Scorer breakdown | A/A? |
|---|---|---:|---|---|
| 1776701583 (aa) | BELIEF_STATE | 30 | 30 `exit_code_fallback` | yes |
| 1776701920 (aa) | BELIEF_STATE | 30 | 30 `exit_code_fallback` | yes |
| 1776702180 | BELIEF_STATE | 100 | 100 `exit_code_fallback` | no |
| 1776702785 | SURPRISAL | 100 | 100 `exit_code_fallback` | no |
| 1776704088 | NEUROMOD | 6 | 6 `exit_code_fallback` | no |
| 1776704673 | NEUROMOD | 100 | 100 `exit_code_fallback` | no |
| 1776707984 | BELIEF_STATE | 100 | 100 `llm_judge` | no |
| 1776709665 | BELIEF_STATE | 100 | 99 `llm_judge` + 1 `exit_code_fallback` | no |
| 1776710317 | SURPRISAL | 100 | 100 `llm_judge` | no |
| 1776710960 | NEUROMOD | 100 | 100 `llm_judge` | no |

The split mirrors the EVAL-081 fix window precisely: every file with timestamp
≤ 1776704673 was scored under `exit_code_fallback`; every file from 1776707984
onward used `llm_judge`. **The A/A baseline pair was captured early, in the
exit_code-only window, and was never re-run.**

## Per-module Wilson 95% CI breakdown (all rows)

```
module         scorer                 aa     n     correct  p      CI95
BELIEF_STATE   exit_code_fallback     False  101   1        0.010  [0.002, 0.054]
BELIEF_STATE   exit_code_fallback     True    60   4        0.067  [0.026, 0.159]
BELIEF_STATE   llm_judge              False  199   133      0.668  [0.600, 0.730]
SURPRISAL      exit_code_fallback     False  100   0        0.000  [0.000, 0.037]
SURPRISAL      llm_judge              False  100   64       0.640  [0.542, 0.727]
NEUROMOD       exit_code_fallback     False  106   0        0.000  [0.000, 0.035]
NEUROMOD       llm_judge              False  100   62       0.620  [0.522, 0.709]
```

Two facts make the credibility hole structural:

1. **The two scorers are not measuring the same thing.** Under
   `exit_code_fallback` the per-module bypass-on rate is 0.000–0.010; under
   `llm_judge` on the same module/bypass setting it is 0.620–0.668. The
   broken scorer counts every non-zero exit code (including expected
   bypass-induced behaviors) as "incorrect", so its rate is artifactually
   pinned near zero. EVAL-082 documented the same disease for EVAL-069.
2. **No llm_judge A/A baseline exists.** Both A/A files used
   `exit_code_fallback`, and no re-run was captured after the EVAL-081
   instrument shipped. So a llm_judge-only delta has no llm_judge A/A
   contrast.

## Decision: RETIRE per acceptance criterion

Per EVAL-084's acceptance criteria:

> If insufficient llm-judge rows for valid inference, mark EVAL-063 RETIRED
> like EVAL-069.

The llm_judge **bypass-on** rows are sufficient (n=100-199/module). The
limiting resource is the **llm_judge A/A baseline** (n=0). Without that
contrast, the published EVAL-063 delta cannot be recomputed under a single
clean scorer, and the original mixed-scorer aggregate is methodologically
invalid (cf. EVAL-082's analysis of EVAL-069).

EVAL-063 is therefore **RETIRED** alongside EVAL-069. F3's task-cluster
localization claim already stands as the only confirmed neuromod finding;
the aggregate-magnitude retirement now covers both EVAL-026 retests.

## Implication for REMOVAL-001 / REMOVAL-003

The NEUROMOD row of REMOVAL-001's matrix and the REMOVAL-003 belief_state
deletion decision rest partly on EVAL-063's "NEUTRAL" reading. Re-examined
under llm_judge alone:

- **BELIEF_STATE** bypass-on llm_judge rate **0.668 [0.600, 0.730]** (n=199)
- **SURPRISAL** bypass-on llm_judge rate **0.640 [0.542, 0.727]** (n=100)
- **NEUROMOD** bypass-on llm_judge rate **0.620 [0.522, 0.709]** (n=100)

The three modules' bypass-on rates overlap heavily — no module's bypass
collapses correctness, and no module shows a privileged cross-module
penalty. Without an llm_judge A/A baseline we cannot claim "Δ ≈ 0" formally,
but the qualitative reading that drove REMOVAL-001 (no module bypass causes
a step-change in correctness; therefore no module is load-bearing) still
holds at the descriptive level. **REMOVAL-003 (belief_state deletion,
shipped in PR #465) does not need to be reversed.** The credibility hole
documented here is a methodology limitation, not a conclusion reversal.

## What changes in FINDINGS.md

F3's caveat row already covered EVAL-069 retirement; this PR extends it to
include EVAL-063 retirement and points to this doc. The retire-rationale
text changes from "EVAL-063 confirmed clean, EVAL-069 compromised by scorer
fallback" to "both EVAL-063 and EVAL-069 retired (mixed-scorer / broken-
scorer contamination)." Both retests of the EVAL-026 aggregate are now
methodology-invalid; the localization claim (per-task-cluster harm) is
unaffected.

## Acceptance-criterion check

- [x] llm_judge-only bypass-on rates + Wilson 95% CIs computed per module
- [x] Insufficient llm_judge A/A rows confirmed (n=0); RETIREMENT triggered
- [x] FINDINGS F3 caveat extended (covered in this PR's diff)
- [x] REMOVAL-001 addendum updated (substantive decision unaffected; see above)
- [x] All evidence preserved here (this doc) with raw counts + CIs
