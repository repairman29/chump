# Preregistration — RESEARCH-022

> **Status:** LOCKED. Post-hoc analysis of existing JSONLs — this prereg
> locks the analysis plan, not a prospective data collection.

## 1. Gap reference

- **Gap ID:** RESEARCH-022
- **Gap title:** Module-use reference analysis — does the agent actually read the scaffolding it is given?
- **Source critique:** [`docs/research/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §5
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21
- **Analysis type:** Post-hoc (existing JSONL data)
- **JSONL range analyzed:** all `logs/ab/eval-025-*.jsonl`,
  `logs/ab/eval-027c-*.jsonl`, `logs/ab/eval-043-*.jsonl` (COG-016 era
  runs, module bypass flags engaged)

## 2. Hypothesis

**H1 (primary).** The agent textually references injected module state in
its output at a non-trivial rate. Formally: across the analyzed JSONLs,
the reference rate for each module (lessons, belief_state, surprisal,
neuromod) is >10% — at least 1 in 10 responses contains identifiable
text tracing back to the module's injected content.

**H0.** Reference rate <10% for ≥1 module — that module is mechanistically
unsupported as a cause of any observed outcome delta.

**Alternative interpretation:** low reference rate does not prove the module
is useless — the agent may condition on it internally without verbalizing.
But it *does* mean outcome deltas cannot be attributed to the module via
any textual mechanism. Mechanism evidence requires positive reference;
the absence of reference is the absence of mechanism evidence.

## 3. Design

Post-hoc regex + LLM-based text analysis of existing trial JSONLs.

### Modules analyzed

- **lessons** — search agent output for bigrams/trigrams from the
  injected lessons block text
- **belief_state** — search for numeric patterns matching the injected
  belief values (e.g. `"my_ability": 0.83` → search output for the string
  "0.83" or "83%" in context of self-reference)
- **surprisal** — search for the injected surprise-flag keywords
  ("unexpected", "surprise", the specific surprising-event summary)
- **neuromod** — search for neuromodulator state names ("dopamine",
  "exploration", "conservative regime") in agent output

### Reference detection — two-stage

1. **Regex stage:** fast scan for exact text matches from injected content.
2. **LLM stage (semantic reference):** where regex finds no match,
   ask claude-sonnet-4-5 whether the agent's output shows *conditional*
   behavior matching the injected state (e.g. agent was told "belief_state:
   low_confidence_in_tool_X" and then avoided tool X).

Positive if either stage detects reference.

## 4. Primary metric

- **`reference_rate_per_module`**: fraction of trials where the agent's
  output contains a positive reference (regex or LLM-detected) to the
  specified module's injected state.
- **Aggregate:** mean reference rate across the 4 modules.

Report per module × task category × (correct / incorrect outcome).

## 5. Secondary metrics

- **Reference × outcome correlation:** does trials with detected references
  correlate with correct outcomes? (Interaction check — if modules help
  only when the agent notices them, this is the strongest mechanism
  evidence available.)
- **Reference × judge-kappa interaction:** do reference trials have higher
  inter-judge agreement? (Tests whether "the agent uses the module" makes
  output more legibly correct.)

## 6. Stopping rule

N/A — exhaustive analysis of all eligible JSONLs at a fixed cutoff date
(2026-04-21). No decision based on incremental data.

## 7. Analysis plan

1. Enumerate eligible JSONLs per §1.
2. For each trial, run regex stage for all 4 modules.
3. For trials with no regex hit, batch-send to LLM stage (bounded to
   10,000 calls total ≈ $10).
4. Report reference rate per module × task category × outcome.
5. Publish cross-tab in `docs/audits/FINDINGS.md` under new "mechanism evidence"
   subsection per finding.

**Exploratory:** cluster agents' reference styles — do some agents
paraphrase, others quote? Does style correlate with correctness?

## 8. Exclusion rules

Trial excluded if:
- Agent output is empty (exit_code ≠ 0).
- Module injection logs show the module was OFF that trial (no state to
  reference).
- LLM-stage rate-limit hit prevented evaluation.

## 9. Decision rule

**If H1 supported (all 4 modules >10% reference rate):** publish as
mechanism evidence. Outcome deltas have textual mechanism support.

**If H1 rejected (any module <10%):** that module is flagged as
"mechanistically unsupported" in CHUMP_FACULTY_MAP.md regardless of
existing outcome deltas. Removal-candidate status elevated.

**Reference × outcome correlation:** if reference rate is low but *in
referred trials* correctness jumps, the finding is "module helps iff
agent notices it" — a novel contribution in its own right.

## 10. Budget

- **Cloud:** ~$15 (LLM-stage calls + regex is free)
- **Wall-clock:** ~4 hours compute + analysis
- **Human time:** ~12 hours (script authoring, validation, writeup)

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Regex misses paraphrased references | LLM stage catches semantic paraphrase |
| LLM stage inflates reference count (false positive) | Spot-check 20 random LLM-positive trials manually; require ≥80% agreement |
| Judge model (sonnet-4-5) has family-bias toward Anthropic-emitted text | Use Llama-3.3-70B as a second-opinion LLM judge on a 100-trial subsample; compare rates |
| Referenced content is in the agent's pretraining (coincidence, not use) | Baseline: compute reference rate against a *shuffled* module-state assignment (Cell A content + Cell B trials). If randomized reference rate is similar to real, rule out genuine use. |

---

## Deviations

*(none yet)*

---

## Result document

`docs/eval/RESEARCH-022-reference-analysis.md` after analysis completes.
