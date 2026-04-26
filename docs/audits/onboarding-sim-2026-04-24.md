# Onboarding Simulation — 2026-04-24

**Auditor:** `scripts/audit/onboarding-sim.sh` (DOC-004)
**Mount:** docs-only (`./docs/` + AGENTS.md + CLAUDE.md)
**Cadence:** monthly (first Monday). Next run: **2026-05-04**.
**Run by:** seed run; bootstraps the cadence. Subsequent runs invoke the
script directly (`scripts/audit/onboarding-sim.sh`) which spawns a fresh
docs-only Claude and writes a fully-populated transcript.

## Why this audit exists

We do not have a paid documentation auditor. A real cold contributor cannot
be summoned cheaply on demand. A docs-only Claude is the closest cheap proxy:
it has never seen the code, has no Chump tooling, and can only learn the
project from the markdown we ship. If it cannot answer the four onboarding
questions correctly, neither can a human.

## Prompt (verbatim from the script)

```
You are a brand-new contributor to the Chump project. You have read access to
ONLY the ./docs/ directory plus the top-level AGENTS.md and CLAUDE.md files.
You CANNOT see source code, scripts, or run commands.

Answer these four questions using ONLY what the docs tell you. Cite the file
path you got each answer from.

  1. What is the very first thing you must run at the start of every session,
     before picking a gap or editing files? Why?
  2. How do you claim a gap so other agents know you are working on it? Where
     does the claim get written?
  3. What is the difference between `gap-reserve.sh` and `gap-claim.sh`, and
     when do you use each?
  4. You have finished your work and want to ship a PR. What command do you
     use, and what does it do for you?
```

## Rubric

| ID | Criterion | Max |
|---|---|---|
| R1 | Pre-flight identified (`gap-preflight.sh`, ambient.jsonl tail, mandatory block) | 2 |
| R2 | Lease semantics correct (`.chump-locks/<session>.json`, NOT gaps.yaml) | 2 |
| R3 | Reserve vs claim distinction (reserve = new ID; claim = existing) | 2 |
| R4 | Ship pipeline (`scripts/bot-merge.sh --gap <id> --auto-merge`) | 2 |
| R5 | Citations present (real file paths inside docs/, AGENTS.md, CLAUDE.md) | 2 |

**Pass threshold:** ≥ 8/10. Score < 8 auto-files a DOC-\* follow-up gap via
`scripts/gap-reserve.sh DOC "onboarding gap: <symptom>"`.

## Seed score (manual review of current docs)

CLAUDE.md is comprehensive on R1, R2, R4. AGENTS.md cross-references it. The
reserve-vs-claim distinction (R3) is documented under "MANDATORY: run before
anything else" but is dense — a cold contributor may need two reads to catch
the "ID must already exist on `origin/main` OR be reserved for your session"
sentence. R5 should always be 2 since the docs are heavily cross-linked.

| Criterion | Score |
|---|---|
| R1 Pre-flight | 2/2 |
| R2 Lease semantics | 2/2 |
| R3 Reserve vs claim | 1/2 |
| R4 Ship pipeline | 2/2 |
| R5 Citations | 2/2 |
| **Total** | **9/10** |

## Follow-ups

R3 scored 1/2 in the seed review — the reserve-vs-claim sequence is correct
in CLAUDE.md but buried inside a long "MANDATORY" section. If the next live
run reproduces the score, file a DOC-\* gap to extract reserve-vs-claim into
its own short subsection with a concrete example.

## Cadence

- **Frequency:** monthly, first Monday.
- **Owner:** whichever agent picks up the calendar reminder; seed run done by
  the DOC-004 implementor.
- **Next run:** 2026-05-04. Append the new file `docs/audits/onboarding-sim-2026-05-04.md`.
