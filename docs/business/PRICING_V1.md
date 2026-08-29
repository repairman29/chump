# Chump Pricing V1 — Experiment Design

**Status:** PROPOSAL — not launched. Pending hosted tier (INFRA-1337) + license split (INFRA-1506, DECIDED) landing first.
**Gap:** INFRA-1507 · related: INFRA-1337 (hosted tier), INFRA-1338 (enterprise SKU), INFRA-1511 (founding-customer mechanic, spec'd separately), INFRA-1506 (license strategy, DECIDED — AGPLv3 + Apache-2.0)
**Last updated:** 2026-08-28

---

## Why this doc exists

Chump doesn't have a price yet, and guessing wrong is expensive in both directions —
too high stalls Team-tier adoption before it starts, too low burns the coordinator
hosting margin and anchors us into a number we can't raise later without a customer
revolt. Rather than pick a number and defend it, this doc proposes a **testable**
3-tier structure and a **Stripe checkout fake-price-test** to validate demand before
INFRA-1337 (hosted tier) writes a single line of billing code.

The mechanic (Section 4) matters more than the numbers (Section 1): the numbers are
placeholders to be replaced by whatever the A/B test converges on.

---

## 1. Three-Tier Table

| Tier | Price | Unit | What's included | Target buyer |
|---|---|---|---|---|
| **Solo** | Free | — | Full OSS fleet coordinator, self-hosted, unlimited agents/gaps, community support (GitHub issues + Discord) | Individual devs, OSS maintainers, evaluators |
| **Team** | $29/seat/mo (annual: $290/seat/yr) | per active seat | Hosted coordinator (no self-hosting `state.db`/NATS), managed NATS broker, cross-repo dashboard, email support, 99.5% uptime SLA | 3–20 person eng teams who want the fleet without running the substrate |
| **Enterprise** | $48,000/yr base (custom above 50 seats) | per-org, annual | Air-gapped deploy, SSO/SAML, dedicated support channel, 99.9% uptime SLA, custom retention policy, architecture review call | Regulated / air-gapped orgs, 50+ engineers |

### Rationale

- **Solo stays free and OSS forever.** This isn't a loss-leader trick — it's the
  license strategy (INFRA-1506: AGPLv3 core) working as intended. Free self-hosted
  usage is what builds the credibility and community the paid tiers monetize.
  Charging for Solo would contradict the AGPLv3 bet and kill the funnel into Team.
- **Team is per-seat because the cost driver is per-seat.** Managed NATS + hosted
  coordinator cost scales with active agent-seats, not with repo count or gap
  volume. Per-fleet pricing (flat rate regardless of team size) was considered and
  rejected — see "Per-seat vs per-fleet" below.
- **Enterprise is per-org/annual, not per-seat**, because the buying motion is
  different: procurement wants one number for a budget line, not a seat count that
  grows unpredictably. Air-gapped deploys also break per-seat metering (no telemetry
  home to phone).
- **Founding-customer discount (INFRA-1511) applies to Team only** — Enterprise
  deals are negotiated individually; discounting a custom-quote tier doesn't fit
  the "first 10, 50% off, case study" mechanic.

### Anchor pricing benchmarks

Used as sanity-check reference points, not as target parity — Chump's unit of
value (an autonomous fleet of agents shipping PRs) doesn't map 1:1 to any of
these, so treat as bracketing, not benchmarking:

| Product | Model | List price (approx, 2026) | Why it's a relevant anchor |
|---|---|---|---|
| Sourcegraph Cody Enterprise | Per-seat/mo, annual contract | ~$59/seat/mo | Closest analog: dev-tooling AI sold to eng orgs, enterprise SSO/air-gap tier exists |
| Cursor Business | Per-seat/mo | ~$40/seat/mo | Individual-dev-tool-turned-team-tool pricing curve; shows the free→paid seat jump other AI coding tools use |
| GitHub Copilot Business | Per-seat/mo | ~$19/seat/mo | Floor anchor — single-feature (autocomplete) tool at the low end of the category |
| GitLab Ultimate | Per-seat/mo | ~$99/seat/mo | Ceiling anchor for a full-platform (not single-feature) dev tool with enterprise governance |

Chump's Team tier ($29/seat/mo) sits between the Copilot floor and the Cody/Cursor
midpoint — reflecting that Chump does more than autocomplete (autonomous multi-agent
shipping) but has zero brand recognition yet, so pricing above the established
players' midpoint would be presumptuous.

### Per-seat vs per-fleet decision

**Decision: per-seat for Team, per-org for Enterprise (mixed model, not uniform).**

| Option | Pro | Con | Verdict |
|---|---|---|---|
| Per-seat (all tiers) | Matches cost driver; familiar SaaS motion; easy self-serve checkout | Penalizes teams that run many agents per human seat (Chump's actual usage pattern skews agent-heavy, not human-heavy) | Team: yes |
| Per-fleet (flat, all tiers) | Simple; doesn't punish agent-heavy usage | Decouples price from cost (a 3-person team running 50 agents costs the same to host as a 30-person team running 50 agents) — margin risk | Rejected for Team |
| Per-org/annual (Enterprise only) | Matches procurement buying motion; works with air-gapped (no telemetry) deploys | Not self-serve; requires a sales touch | Enterprise: yes |

The mixed model is a deliberate hedge: Team stays self-serve and metered (matches
cost), Enterprise stays negotiated and flat (matches the buying motion). Revisit
if usage data from the A/B test (Section 4) shows agent-count, not seat-count, is
the dominant cost driver — that would argue for metering Team by agent-hours
instead of seats, a v2 question, not a v1 blocker.

---

## 2. Landing Page Variants (Stripe Checkout A/B Test)

Two landing-page copy variants, testing **value-framing angle** (autonomy vs.
cost-savings) against the same 3-tier structure and same Stripe checkout flow.
Full copy specs:

- [`pricing-landing-variant-a.md`](./pricing-landing-variant-a.md) — **"Autonomy" framing.** Leads with "ship while you sleep" / fleet-of-agents autonomy as the hook. Targets the audience already excited about agentic coding.
- [`pricing-landing-variant-b.md`](./pricing-landing-variant-b.md) — **"Cost-savings" framing.** Leads with headcount-equivalent framing ("what a fleet costs vs. what a hire costs"). Targets an engineering-manager budget-holder audience.

Both variants use identical pricing (Section 1), identical Stripe Checkout
integration, and differ only in landing-page copy/hero framing — isolating the
variable being tested to "does autonomy-first or cost-first messaging convert
better," not pricing itself.

---

## 3. Decision Rule

Measured over the test window (Section 4) on **Team-tier Stripe Checkout
conversion rate** = (checkout sessions completed) / (landing page visitors who
reach the pricing section):

| Tier-2 (Team) conversion | Decision |
|---|---|
| **> 5%** | Ship it. Build INFRA-1337 hosted tier at this price point; open founding-customer program (INFRA-1511) to convert test signups. |
| **1–5%** | Iterate. Price or framing is close but not validated — re-test with an adjusted price point (try $19/seat and $39/seat brackets) or swap landing copy angle before committing engineering time to INFRA-1337. |
| **< 1%** | Free-only, forever. Do not build the hosted tier. Solo (free, OSS) remains the only distribution; monetize via consulting/support/Enterprise custom deals only if they arise inbound, not via a self-serve Team tier. |

This rule exists specifically so a low-signal test result **kills** the hosted-tier
build rather than becoming sunk-cost justification for shipping it anyway —
INFRA-1337 is real engineering effort (billing, entitlements, hosted NATS ops)
that shouldn't start until Team-tier demand is validated at >1%.

---

## 4. Test Mechanics

- **Instrument:** Stripe Checkout in test mode, fake-price-test pattern — landing
  page collects email + triggers a real Stripe Checkout session at the proposed
  Team price; a page immediately after checkout confirmation explains this was a
  demand-validation test, no card is charged (Checkout session is voided /
  refunded automatically), and offers a spot on the founding-customer waitlist
  (INFRA-1511).
- **Traffic:** Split 50/50 between variant A and variant B via query-param or
  simple cookie-based bucketing; no need for a dedicated experimentation platform
  at this volume.
- **Window:** Minimum 2 weeks or 500 unique pricing-page visitors, whichever is
  longer — avoids a false read from a single-day traffic spike (e.g. a HN
  front-page hit skewing toward one audience).
- **What gets measured per variant:** visitors → pricing-section-viewed →
  checkout-started → checkout-completed, plus which tier (Solo/Team/Enterprise)
  each checkout-started event targeted.
- **Founding-customer mechanic:** the > 5% path routes converted test signups into
  the founding-customer offer spec'd in INFRA-1511 (10 seats, 50% off 12 months,
  case-study rights) — see [`FOUNDING_CUSTOMER_OFFER.md`](./FOUNDING_CUSTOMER_OFFER.md).
  That doc's mechanics are reusable as-is; this doc's decision rule is what gates
  whether the offer opens at all.

---

## Open questions (not blockers for this doc)

- Should Team pricing be seat-metered or agent-hour-metered long-term? (Section 1,
  per-seat vs per-fleet — flagged as a v2 question pending usage data.)
- Does Enterprise need a mid-tier between Team (self-serve) and Enterprise
  (custom-quote) for 20–50 seat orgs that want SSO but not air-gap? Not modeled
  here; revisit if Enterprise inbound skews toward that band.
- Annual-vs-monthly discount depth ($290/yr = ~17% off $29×12=$348) is a
  placeholder ratio, not benchmarked against the anchor table — fine for a test,
  should be revisited before real billing code ships.
