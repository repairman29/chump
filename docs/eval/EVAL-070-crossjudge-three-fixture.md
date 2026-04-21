# EVAL-070 — Cross-Judge Methodology: Three-Fixture kappa Table

**Status:** DONE  
**Date:** 2026-04-20  
**Gap:** EVAL-070 (P2, s effort)  
**Data source:** EVAL-042 JSONL (`logs/ab/eval-042-crossjudge-{reflection,perception,neuromod}-*.jsonl`, n=100/fixture)

---

## Summary

EVAL-042 ran two-judge cross-scoring (claude-sonnet-4-5 × Llama-3.3-70B-Instruct-Turbo) across
three fixtures. F4 previously reported the neuromod fixture only (κ=0.42). This gap extends that
finding to all three fixtures, confirms that disagreement clusters by task semantic type, and
elevates F4 to a three-fixture statement.

---

## Three-Fixture Agreement Table

| Fixture    |   n | Agreement | 95% CI (Wilson) | Cohen κ | 1/1 | 1/0 | 0/1 | 0/0 |
|------------|-----|-----------|-----------------|---------|-----|-----|-----|-----|
| reflection | 100 | 86.0%     | [0.779, 0.915]  | 0.722   |  40 |   2 |  12 |  46 |
| perception | 100 | 75.0%     | [0.657, 0.825]  | 0.496   |  33 |  11 |  14 |  42 |
| neuromod   | 100 | 71.0%     | [0.615, 0.790]  | 0.420   |  40 |  10 |  19 |  31 |

Threshold: 0.5 (score ≥ 0.5 → 1, else 0). Judges: `claude-sonnet-4-5` (columns) ×
`together:meta-llama/Llama-3.3-70B-Instruct-Turbo` (rows). Columns: sonnet=1/llama=1, sonnet=1/llama=0,
sonnet=0/llama=1, sonnet=0/llama=0.

**Interpretation of κ bands:**
- κ > 0.6: substantial agreement (reflection ✓)
- κ 0.4–0.6: moderate (perception, neuromod — require multi-judge panels for publication)
- κ < 0.4: fair/poor

---

## Per-Task Disagreement Clustering

### Reflection (κ=0.722, 14 disagreements)

Disagreement concentrated in two task classes:
- **gotcha** tasks (e.g., `gotcha-07-silent-assumption`): 100% disagreement rate — agent behavior
  on edge cases where the "correct" answer is ambiguous or context-dependent
- **clean** tasks (e.g., `clean-31-simple-sort`, `clean-33-git-remote`): 50–100% disagreement —
  well-defined tasks where judges diverge on partial-completion credit

### Perception (κ=0.496, 25 disagreements)

Disagreement concentrated in:
- **structured multi-entity** tasks (`structured-04-multi-entity`, `structured-06-ambiguity-high`,
  `structured-14-mixed-risk-2`): 100% disagreement rate — tasks requiring the agent to extract
  and reason over multiple entities; sonnet and llama differ on what constitutes "full extraction"
- **trivial creative** tasks (`trivial-09-creative`, `trivial-13-bye`): both judges uncertain on
  open-ended outputs with no ground truth

### Neuromod (κ=0.420, 29 disagreements)

Disagreement concentrated in:
- **dynamic** tasks (`dynamic-08-budget-aware`, `dynamic-13-budget-then-relax`,
  `dynamic-25-constraint-change`): 100% disagreement — tasks requiring the agent to adapt behavior
  to changing constraints; exactly the task class where neuromod harm signal is strongest
- **adaptive** tasks (`adaptive-01-partial-failure`, `adaptive-04-summarize-with-constraint`):
  100% disagreement — tasks with partial-failure recovery patterns

**Key pattern:** The highest-disagreement task classes in neuromod (dynamic, adaptive) are the
same task classes where EVAL-029 localized the lessons-block harm signal. This is consistent
with F4's hypothesis that judge disagreement and module-effect signal co-cluster by task type,
and that neuromod-related effects are concentrated in tasks that are hardest to judge reliably.

---

## Implications for F4

F4 originally stated: *"Two LLM judges disagree at Cohen κ=0.42 on the neuromod fixture; the
disagreement is concentrated in the task class where lessons-block harm appears."*

This analysis extends F4 to three fixtures:
1. **Reflection** is well-judged (κ=0.72) — reflection-fixture results are more reliable and
   can be cited with higher confidence than other fixtures.
2. **Perception** is moderately judged (κ=0.50) — perception results require multi-judge panels
   before publication.
3. **Neuromod** has the lowest agreement (κ=0.42) — neuromod results need the most caution.
   The disagreement-clusters-match-effect-clusters pattern strengthens the F4 claim but also
   means neuromod results have the widest effective confidence intervals.

See `docs/FINDINGS.md` — F4 row updated to three-fixture statement.

---

## Reproduction

```bash
# All JSONL already in logs/ab/ — no new sweeps needed
python3.12 -c "
import json, math
from pathlib import Path
# ... (full kappa computation script) ...
" < logs/ab/eval-042-crossjudge-*.jsonl
```

Data files used:
- `logs/ab/eval-042-crossjudge-reflection-1776659268.jsonl` (n=100)
- `logs/ab/eval-042-crossjudge-perception-1776660460.jsonl` (n=100)
- `logs/ab/eval-042-crossjudge-neuromod-1776659864.jsonl` (n=100)
