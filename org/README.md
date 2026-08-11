---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-11
builds_on: [RUN_THE_BUSINESS_2026-08-09, FACTORY_ORG_MODEL_2026-08-08]
---
# `org/` — the company you can walk

This tree **is** the org chart. Walk the folders like walking the office. Each
department is a folder; each chair is a `roles/<chair>.md`. The frontmatter is the
truth — walking the tree shows you not a diagram but **what's actually staffed vs.
dormant, who owns what, and which gaps drive it.**

> Anchored on **DOC-089**: [`../docs/strategy/RUN_THE_BUSINESS_2026-08-09.md`](../docs/strategy/RUN_THE_BUSINESS_2026-08-09.md)
> (the two arms) + [`../docs/strategy/FACTORY_ORG_MODEL_2026-08-08.md`](../docs/strategy/FACTORY_ORG_MODEL_2026-08-08.md)
> (a job = one typed artifact, one gated pipeline, one chair).

## The two arms

- **`BUILD/`** — turn dreams into products. The engineering factory. **Live.**
- **`RUN/`** — operate the business: publish, market, sell, support, measure, bill,
  keep the lights on. *"A software business is only ~25–35% code; the other ~65–75%
  is running it"* (DOC-083). **Mostly dormant** — named, not driven.

COTG ("a dreamer gets a finished tool that *runs*") only works when **both** arms
self-run. Today the foundry built the 35% and left the 65% as a diagram. This tree
makes that 65% visible so it stops being invisible.

## What we have vs. what we need (the honest read, 2026-08-11)

- **We HAVE the knowledge** — pricing strategy, marketing plans, launch checklists,
  pitch decks, a role taxonomy — richly, mostly **dormant in `beast-mode` and
  scattered across the fleet** (each chair's `mines:` points at the real asset).
- **We NEED it to *run*** — none of it is a driven, gated organ. The gap is
  **activation, not invention.** Mine the dormant engine → wire it as a chair the
  running fleet works toward a gated artifact.

## How to read a chair (`roles/<chair>.md` frontmatter)

```yaml
chair: publisher
department: RUN/publication
status: dormant          # ✅ online · 🟡 built · 🟠 thin · ⚪ dormant · ❌ missing
owns: launch-post        # the ONE typed artifact this chair produces
gate: captain-approved-and-posted   # what proves it done (human only on the irreversible click)
driven_by: [EFFECTIVE-364, EFFECTIVE-365]   # the gaps the running fleet executes
mines: beast-mode/PRODUCT_HUNT_POST.md + LAUNCH_CHECKLIST.md   # the dormant engine to pull from
last_verified: 2026-08-11
```

## The one law (why it doesn't rot)

**Org-chart-as-driven-work, never a dashboard.** BEAST-MODE built the org chart as a
*UI* — role pages, no gates — and went dormant (23 commits, dead since Aug 2). Here a
chair is a set of gaps producing a gated artifact, or it doesn't exist. A department
with no `driven_by` and no artifact is honestly stamped `dormant`, so the tree never
lies about what's real.

## Customer 0 — the order we staff RUN (DOC-089)

We run **our own** foundry's business on each chair before it's a product:
1. **Operations / self-heal** — the factory fixes its own sloppiness (in progress).
2. **Publication + Analytics** — ship → *told* + measure whether it landed. **#1 keystone.**
3. **Growth** — demand on a cadence.
4. **Support / Sales / Finance** — as a product earns real users and revenue.
