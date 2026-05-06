---
doc_tag: rule
owner_gap: INFRA-501
applies_to: [tech-writer, doc-gardener, scribe, frontier-scientist, cold-water, any agent that writes to docs/, book/, or opens PRs against the public repo, bot-merge.sh, any agent that creates commits or PRs]
---

# Research privacy rule

> **Any agent that writes to docs/, book/src/, blog posts, briefs, or
> opens PRs against the public `repairman29/chump` repo MUST NOT
> reproduce specific empirical results from the cognitive-architecture
> research stream in public artifacts.**
>
> Specifically prohibited in public docs, PR titles, PR bodies, commit
> messages, blog posts, and chronicle entries:
> - Specific deltas (e.g. "+0.33 hallucination rate", "+0.137",
>   "−0.10 to −0.16 mean delta")
> - Specific n-values tied to model results (e.g. "n=100 cross-family",
>   "n=50 single-judge")
> - Specific model-tier names paired with outcomes (e.g.
>   "haiku-4-5 …", "sonnet-4-5 …", "opus-4-5 …" coupled with rates,
>   percentages, or harm/help language)
> - EVAL-IDs cited as evidence with attached numbers
>   (e.g. "EVAL-025, n=100, cross-family judge")
> - The phrase "tier-dependent injection finding" coupled with specific
>   magnitudes
> - Per-cell forensics tables, ablation result tables, judge-agreement κ
>   values, hallucination rates, A/A noise floor numbers
>
> **Why:** rounds 1–4 of the 2026-05-05 IP-protection sweep moved the
> validated empirical finding (and its supporting per-eval results, paper
> drafts, and finding-restatement docs) to the private companion repo
> `chump-proprietary` so that publication channels can be controlled.
> Auto-doc agents that summarize "what shipped this week" or "what we
> learned from EVAL-XXX" will re-leak the same content unless they
> follow this rule.

## What you CAN write in public docs

- **Methodology statements:** "We use Wilson 95% CIs", "A/A baseline
  required", "cross-family judge composition", "preregistered eval
  scope", "exit-code scorer prohibited (use llm-judge)".
- **Process citations:** "see `docs/process/RESEARCH_INTEGRITY.md` for
  the methodology directive and prohibited-claims list".
- **Generic direction language:** "instruction injection has
  systematically different effects by model tier and task class — see
  internal results for specifics".
- **Code-level changes:** "shipped COG-016 (anti-hallucination
  directive)", "added `CHUMP_BYPASS_BELIEF_STATE` ablation flag" — code
  identifiers are public, the *measured outcomes* are not.
- **Gap-registry status:** "EVAL-043 status: done" — status changes are
  public, the *result content* is not.

## How to handle "what shipped this week" summaries

When the tech writer or scribe summarizes recent eval activity for the
public engineering log:

- Cite the gap ID and code change ("EVAL-049 added a binary-mode
  ablation harness in `scripts/ab-harness/run-ablation-sweep.py`")
- Link to internal-only result locations as private pointers
  ("results: see `chump-proprietary/eval/EVAL-049-binary-ablation.md`")
- Do **not** copy the result table, the model-by-model deltas, or the
  judge-by-judge agreement rates into the public summary
- If the natural summary requires specific numbers to make sense,
  rewrite the summary as a methodology note ("EVAL-049 confirmed the
  binary-mode harness is reproducible; results internal") rather than a
  numbers-laden recap

## How to handle the dissertation / book content

The dissertation (`book/src/dissertation.md`) is allowed to describe the
**architecture** in detail (faculty list, file paths, design patterns).
It is NOT allowed to claim validated outcomes for any module that
isn't trivially public. The integrity caveat at the top is the canonical
language; do not lengthen it with specific findings.

## PR title and commit subject hygiene (INFRA-501)

PR titles, commit subjects, and branch names are **public-facing** and
indexed by GitHub search. They are a leak vector independent of file
content.

### Allowed in PR titles and commit subjects

- Gap-registry identifiers and status changes: `INFRA-501: ship PR/commit hygiene policy`
- Code-level identifiers: function names, flag names, file paths, crate names
- Methodology pointers: `add Wilson-CI ablation harness`, `wire llm-judge exit-code scorer`
- Opaque references to internal work streams: `SWARM-005: coordination scaffolding`
- Generic engineering verbs: `fix`, `add`, `remove`, `refactor`, `wire`, `ship`

### Prohibited in PR titles and commit subjects

- Specific empirical findings, deltas, rates, or model-tier outcomes
- Language that describes the IP-protection sweep itself and what it moved
  (e.g. `round N — bulk move per-eval results … to private`,
  `redact RESEARCH_INTEGRITY directive`, `move findings index … to private`)
- The proprietary-domain vocabulary: `injection finding`, `tier-dependent`,
  `hallucination rate`, `publication draft`, `research thesis`, specific
  eval numbers
- Explanations of _why_ content is being redacted or relocated
  (the fact that something was protected is itself informative)

> **Operator approval required** for any PR title or commit subject that
> mentions the IP-protection mechanic itself (e.g. "IP sweep", "move to
> private", "redact"). If the change cannot be described without revealing
> the mechanic, use a generic engineering label: `docs: housekeeping`,
> `gaps: registry cleanup`, or just the gap ID.

### Guidance for bot-merge.sh and PR-creation paths

`bot-merge.sh` derives `PR_TITLE` from the last commit subject on the branch.
Before running `bot-merge.sh`, ensure that commit subject passes this rule.
If the title is non-compliant, amend the last commit (with `git commit --amend`)
to use a compliant subject before invoking `bot-merge.sh`.

The script itself cannot programmatically detect all policy violations — the
author is responsible for compliance before opening the PR.

## Past-PR audit (INFRA-501, 2026-05-06)

Audit of `main` commit history for PR titles that reveal IP-protection
mechanics or proprietary-domain content. Column: **action** = `edit`
(GitHub PR title edited via `gh pr edit`; git log unchanged) or `accept`
(accepted as historical record — either already vague enough or not worth
the noise of a correction).

| PR   | Original title (abbreviated)                                                          | Issue                                           | Action  |
|------|---------------------------------------------------------------------------------------|-------------------------------------------------|---------|
| #1136 | `docs: move strategy + research docs to private repo`                                | Reveals research docs existed and were moved    | edit    |
| #1138 | `docs: round 2 — kill GitHub Pages, move findings index + HN drafts … to private`   | Names specific artifacts moved; sweep round     | edit    |
| #1141 | `docs: round 3 — move publication drafts to private, redact research thesis …`       | Names publication drafts + research thesis      | edit    |
| #1142 | `docs: round 4 — bulk move per-eval results + research/audits/briefs to private; redact RESEARCH_INTEGRITY directive` | Most revealing: per-eval results, directive redaction | edit |
| #1149 | `gaps: rename SWARM-001..013 titles to opaque + file INFRA-500 …`                   | Reveals SWARM titles were opaque-ified          | accept  |
| #1144 | `docs/agents: bind tech-writer / doc-gardener / … to RESEARCH_PRIVACY rule`         | Neutral — names rule, not findings              | accept  |

**Edited titles** (applied via `gh pr edit --title`; git log on main unchanged):

- #1136 → `docs: relocate private-scope documents to companion repo`
- #1138 → `docs: IP sweep round 2 — relocate private-scope documents`
- #1141 → `docs: IP sweep round 3 — relocate private-scope documents`
- #1142 → `docs: IP sweep round 4 — relocate private-scope documents`

Note: "IP sweep round N" is retained to preserve meaningful chronology
without revealing what was swept. The specific artifacts (per-eval results,
HN drafts, publication drafts, directive text) are removed from visibility.

## Escalation

If a writing task seems to require leaking a specific number, **stop and
file a gap** describing the desired summary. The operator can decide
whether to publish the number externally (e.g. as part of a paper) or
keep it internal. Do not unilaterally decide that "this number is small
enough to share" — the privacy boundary is at the boundary of
Chump-internal vs published-by-the-operator, not at any specific
magnitude.
