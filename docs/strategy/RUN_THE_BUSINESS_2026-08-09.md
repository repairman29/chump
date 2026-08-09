---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-09
builds_on: [FACTORY_ORG_MODEL_2026-08-08, ARTIFACT_ORGANIZATION_2026-08-05]
---

# Run the Business — the other half of COTG (we are customer 0)

> **The thesis.** ChumpOS's stated vision is *turn dreams into products* (BUILD).
> But a software business is only ~25–35% code (DOC-083). The other ~65–75% is
> **running the business**: selling, marketing, publishing, supporting, measuring,
> billing, keeping the lights on. **We productize running a business — build AND
> run — and we are customer 0:** we run our own foundry on it first, prove each
> department on ourselves, then it's a product someone else can run their business on.

## Two arms, one factory

- **BUILD — turn dreams into products.** The engineering factory. Live and productized-ish (self-dispatch, gates, ship, self-heal). Org chart L2–L5.
- **RUN — operate the business.** The dormant departments: publish, market, sell, support, measure, bill, operate. Org chart L1/L6/L7/L8 + the sales/support/finance departments that DOC-083 found dormant across the fleet.

COTG "just works" only when **both** arms self-run. Today we built the 35% and left the 65% as a diagram.

## Why RUN is dormant (the roadmap miss)

`ROADMAP.md` and `MISSION.md` have **zero** run-the-business framing (grepped 2026-08-09: 0 hits for run-the-business / sales / marketing / finance / support). The roadmap is what points the fleet — and it only knows how to BUILD. So the RUN organs never get worked, and stay dormant forever. The org chart names them; nothing drives them. **This doc is the missing half of the roadmap.**

## The Run-the-Business departments

From the org chart (Factory Org Model) + the DOC-083 fleet survey (the dormant engines already exist — mine before build). Status legend: ✅ online · 🟡 built · 🟠 thin · ❌ missing.

| Department | The job | Status | Keystone / organ | Dormant engine to MINE (DOC-083) | Driving gap |
|---|---|---|---|---|---|
| **Operations / self-heal** | keep the factory alive + honest | 🟠 | self-heal daemon + the VOA self-fix loop | this session | VOA-006/007, RESILIENT-257 |
| **Publication / tell-people** | ship → **told** | ❌ | PUBLISHER.md (draft→approve→drive→track) | beast-mode HN/PH launch scripts | **EFFECTIVE-364/365** |
| **Growth / marketing** | create demand | 🟠 | release notes, launch posts, ghostwriter | beast-mode `GhostWriterService`, launch generators | **EFFECTIVE-356** |
| **Analytics / measure** | know what's actually happening | 🟠 | usage ledger + KPI rollup | smugglers `RevenueAnalyticsService`, `analytics-platform-service` repo | usage-ledger gap |
| **Customer success / support** | keep the users you win | ❌ | knowledge-base + support agent | slidemate KB engine, echeo `SupportChatbot` | new |
| **Sales** | convert interest to revenue | ❌ | pricing page, decks, outliner | slidemate deck product, beast-mode pricing | new |
| **Finance / billing** | get paid, stay solvent | ❌ | billing + ledger | upshift billing consolidation | new |

## Customer 0 — the dogfood order

We run **our** business on each department before it's a product. Order by what our own foundry needs next:

1. **Operations (self-heal)** — the factory catches + fixes its own sloppiness (the VOA→fleet loop). *In progress this session; the loop is broken until gap-import is resilient (VOA-006).*
2. **Publication + Analytics** — tell people about Olive and measure whether it lands. **The #1 keystone** — it's the mechanical fix for "built ≠ shipped ≠ told," and it's the first department a real product needs.
3. **Growth / marketing** — the herald/launch engine, on a cadence.
4. **Support / sales / finance** — as Olive earns real users and revenue.

Each department, proven on us, becomes a productized "run-your-business" capability — because if it can run *our* messy real foundry, it can run someone else's.

## The productization bar ("just works")

Two properties, or it's not COTG:
1. **Self-healing** — the factory detects and files-and-fixes its own defects (the VOA loop: hit friction → `chump voice` → dedup against Almanac → fleet fixes). The ops defects found this session (false-positive alerts, broken import, empty-default Almanac, size-clamp) are the current gap between "runs" and "just works."
2. **Human only on the irreversible click** — publish, spend, send. Everything up to the button self-runs.

**The BEAST-MODE warning applies (DOC-083 §2):** it built the org chart as a *UI* — role dashboards, no gates — and went dormant. This is org-chart-as-**driven-work** (each department is a set of gaps the running fleet executes toward a gated artifact), never a dashboard.

## Near-term driving gaps (so the *running* fleet works the business)

1. **Make the self-fix loop real:** resilient `chump gap import` (VOA-006) + Almanac mine-before-holler default (VOA-007) + honest auth alert (VOA-003). → Operations "just works."
2. **Publication + Feedback:** EFFECTIVE-364/365 — the #1 open chair.
3. **Analytics usage ledger** — Olive's headless usage + a fleet KPI rollup (the receipts you publish from).
4. **Reconcile `ROADMAP.md`** — add this Run-the-Business track as a co-equal arm so the roadmap stops being build-only.

_Filed 2026-08-09 under DOC-089. Builds on FACTORY_ORG_MODEL (the departments) + DOC-083 (the dormant engines). The org chart is the blueprint; this is the half of the roadmap that drives it._
