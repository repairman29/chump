---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Oops Log — Broken Instruments & Retractions

This file is a **journal of research mistakes**: broken scorers, invalidated
protocols, and any claim we later learned was wrong or oversold.

It exists so:

- `docs/FINDINGS.md` can stay **clean, citable, and uncluttered**, while still being
  honest.
- We retain a durable record of *how* a mistake happened and *what* changed.

This is not a “blame” doc. It’s the audit trail that keeps the project’s public
claims aligned with `docs/RESEARCH_INTEGRITY.md`.

---

## O1. Exit-code scorer invalidated (retired)

- **What happened**: Some A/B sweeps were scored with an exit-code-only path
  (`--scorer exit-code` / fallback variants) that did not reflect response quality.
- **Why it matters**: It can produce large apparent deltas that are pure measurement artifact.
- **Current stance**: Retired. Exit-code scoring is prohibited as a primary scorer.
- **Primary policy**: `docs/RESEARCH_INTEGRITY.md` (Required Methodology Standards).
- **Where to look**: EVAL-060 / EVAL-061 / EVAL-069 and any EVAL doc explicitly labeled
  “instrument fix”, “rescore”, “retired”.

## O2. Judge prompt asymmetry misread as “family disagreement” (reframed)

- **What happened**: Cross-judge disagreement was initially interpreted as model-family
  divergence (“judges instantiate different answers”) under *different rubrics*.
- **Fix / reframing**: Under a shared strict binary rubric, disagreement collapsed to
  100% agreement on the compared rows (EVAL-073).
- **Current stance**: The methodological conclusion stands (“shared strict rubric required”),
  but the “family disagreement” narrative is retired.

## O3. Any future retraction protocol

When a claim is discovered to be wrong or overstated:

- **Update**: `docs/FINDINGS.md` should be updated first (so public readers see the correction).
- **Record**: Add an entry here with:
  - what was claimed
  - what was wrong
  - what fixed it (EVAL doc / PR / commit)
  - what is safe to claim now

