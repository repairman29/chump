---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-08
unifies: [DOC-079, DOC-083, DOC-088]
---

# The Factory Org Model — one framework, jobs-to-be-done, legible to humans and agents

> **What this is.** The single operating model for the factory-and-business.
> It unifies three earlier lenses that were never reconciled —
> [`SOFTWARE_FACTORY_MATRIX_2026-08-05.md`](./SOFTWARE_FACTORY_MATRIX_2026-08-05.md)
> (DOC-079, the 8-layer model), [`ARTIFACT_ORGANIZATION_2026-08-05.md`](./ARTIFACT_ORGANIZATION_2026-08-05.md)
> (DOC-083, the artifact pipeline), and the registry-coordination figure
> (DOC-088) — into **one thing a human and an agent read the same way.**
> When these disagree, this doc wins; the three remain as the reasoning behind it.

## The one idea

**A factory job is one typed artifact, produced through one gated pipeline, owned
by one chair.** That sentence is the whole framework.

- A **human** reads a job as *"a thing to be done — who owns it, is it real, what's
  the receipt."*
- An **agent** reads the same job as *"typed Input → Process → Output, a Gate I must
  pass, a chair to claim."* Routable.

Adding a capability means **teaching the factory one new job (one row)** — never
reorganizing chairs. That is the flexibility, and it is what avoids the failure
mode below.

## The one law (why it's jobs, not an org chart)

**BEAST-MODE already built the org chart of chairs — role dashboards, role
training corpora, bot registries — and it went dormant** (DOC-083 §2: "the org
chart as UI, with no gates and no verified output"). The lesson is load-bearing:

> A chair with no gate is not a job. It is a dashboard. Dashboards go dormant.

So every job in this model **carries its gate**. If you can't name the gate an
artifact must pass, it isn't a job yet — it's an idea, and it goes to intake
(EFFECTIVE-357), not the registry.

## The shared spine (every job runs the same six stages)

Every job — a React component, a migration, a release note, a launch post, a help
article, a price change — runs the identical pipeline (DOC-083):

```
Inputs → Process → Outputs → Quality Gate → Publication → Feedback
```

Chump implements **4 of 6** today (Inputs→Process→Outputs→Gate map to
gap(AC)→claim/worktree→diff→preflight/CI/judge). The two missing stages are the
real frontier, and they already have owners:
- **Publication** — the pipeline ends at merge; this is the mechanical cause of
  "built ≠ shipped ≠ told." Owner: **EFFECTIVE-364/365** (`~/Projects/PUBLISHER.md`).
- **Feedback** — holler is inbound-only; no where-published receipt closes the
  loop. Owner: **EFFECTIVE-364**.

Because the spine is shared, a job row never re-describes it. A row only says:
*which artifact, which chair, which gate, is it real, what to mine.*

## Honesty legend (same one, fleet-wide)

`✅ online` (verified working) · `🟡 built` (code exists, unproven) ·
`🟠 thin` (partial / dormant-elsewhere, mine-before-build) · `❌ missing` (design only)

Everything cited from a dormant repo is **claimed capability, not verified value**
(REALITY_MAP §0). A `🟠` pointing at another repo means *dig here first*, not
*this runs*.

## The registry — the jobs (this table is the model)

This table is **both projections at once**: prose a human skims, and a
pipe-delimited grid an agent parses. `Dept` groups by the 8-layer model (the
coarse map); `Chair` is the owner (a live organ, a fleet role, or a human);
`Gate` is the non-negotiable each artifact passes; `Status` is honest;
`Mine / receipt` is the predecessor to pull from before building fresh.

| Job (artifact) | Dept | Chair (owner) | Gate | Status | Mine / receipt |
|---|---|---|---|---|---|
| Objective → gap+AC (intake) | L1 Exec | ❌ intake organ → **EFFECTIVE-357** | AC well-formed + traces to outcome (MISSION-045) | 🟠 | onboard can't read intent docs (EFFECTIVE-416) |
| Architecture decision | L2 Arch | 🟠 `chump gap decompose` / architect.rs | decompose review passes | 🟠 | `chump-handoff/architect.rs` (live) |
| Design pass (UI/UX/a11y) | L3 Design | ❌ → **EFFECTIVE-358** | contrast-audit + token discipline | 🟠 | `ExpertDesigner` (beast-mode), contrast-audit (slidemate) |
| Code change | L4 Eng | ✅ **chump** (worker loop) | preflight + CI + AC-judge | ✅ | live — zero-touch ships this week |
| Quality gate (the gauntlet) | L5 Quality | ✅ chump gauntlet + eval | gate gauntlet green | ✅ | live |
| Docs / help article | L5 Docs | 🟡 docs corpus + DEPTH.md | DEPTH tier named + voice-lint | 🟠 | 579-file corpus (chump) |
| Release note | L7 Growth | 🟡 → **EFFECTIVE-356** | voice-lint (STYLE.md) | 🟠 | `ReleaseNotesGenerator` (beast-mode) |
| Launch post (HN/PH/LinkedIn) | L7 Growth | ❌ herald / → **EFFECTIVE-365** | Jeff-approved, per-post, human-sent | ❌ | HN + PH launch generators (beast-mode) |
| Publication (ship → target) | (spine) | ❌ → **EFFECTIVE-364** | publish-target registry + where-published receipt | ❌ | `PUBLISHER.md` design only |
| Deploy / rollback | L6 Ops | ✅ vercel-bosun + rollback ×3 | verify-by-hash live | 🟠 | rollback machinery (smugglers/slidemate) |
| Analytics / KPI | L8 CI | 🟡 kpi_report + analytics engines | metric traces to a source | 🟠 | `RevenueAnalyticsService`, analytics-platform-service |
| Continuous improvement | L8 CI | ✅ chump L8 (MISSION-045) | pillar-graded, outcome-traced | ✅ | live |

## The one lifecycle (how a job enters and moves — this is the flexibility)

```
1. New need              → write ONE job row: artifact type + gate + AC.
2. No chair?             → file a gap with that AC (MISSION-045 requires outcome).
                           WorkerCapability (fleet_capability.rs) scores who fills it.
3. Job runs the spine    → Output MUST pass its Gate → Publication → Feedback.
4. almanac indexes it    → future work discovers the chair; no re-derivation.
```

Step 2 *is* the "invent the chair" rule you asked for: an ownerless job is not a
hole in an org chart — it's a **gap with acceptance criteria**, which the fleet's
picker and `almanac` already act on. This is why the model stays flexible: the org
never gets "restructured"; jobs get added, and chairs get filled by scoring, not
by decree.

## What a human and an agent each do with this doc

| | Human (Jeff / a person) | Agent (chump / a worker) |
|---|---|---|
| **Reads a row as** | a job to be done, its owner, is it real | typed I/O + a gate + a claimable chair |
| **"Add a capability"** | add one row | register one artifact type + its gate |
| **"Who does X?"** | scan the Chair column | score WorkerCapability, claim the gap |
| **"Is it real?"** | Status legend | preflight/CI/judge on the gate |
| **Ground truth** | this table + receipts | `almanac` indexes this doc |

Same source. Two projections. That is "understand together."

## The open chairs (the honest worklist, ranked)

These are the `❌`/`🟠` rows above, in ship order — the two spine gaps first
because they unblock the whole right half of the table:

1. **Publication + Feedback** (EFFECTIVE-364, then 365) — turns "built" into
   "shipped ≠ told." The single highest-impact gap; L7 reads empty *because*
   these two stages don't exist.
2. **Intake** (EFFECTIVE-357) — the front door; a non-technical person's plain
   words → a well-formed job. This is the COTG on-ramp.
3. **Design pass** (EFFECTIVE-358) + **first non-code artifact** (EFFECTIVE-356,
   release notes) — prove the spine is artifact-agnostic, not code-only.

## What this doc does NOT authorize

No dormant repo goes public and no buried engine gets wired without its own
mine-before-archive extraction, security review, and release-auditor GO. The
`Mine / receipt` column is a map of *where to dig*, not a claim the engines run
(DOC-083 §4).

_Filed 2026-08-08 under DOC-089. Unifies DOC-079 (layers) + DOC-083 (artifact
pipeline) + DOC-088 (registry figure). Implementing gaps unchanged:
356/357/358/363/364/365._
