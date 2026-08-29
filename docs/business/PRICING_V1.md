# Chump Pricing V1 — 3-Tier Experiment Design

**Gap:** INFRA-1507 · related: INFRA-1337 (hosted tier), INFRA-1338 (enterprise SKU),
INFRA-1511 (founding-customer mechanic, spec'd separately in
[FOUNDING_CUSTOMER_OFFER.md](./FOUNDING_CUSTOMER_OFFER.md)), INFRA-1506 (license strategy)
**Status:** Experiment design — pricing itself is not final. This document is the
Stripe checkout A/B test that produces the data to set it.
**Last updated:** 2026-08-28

---

## Why this needs to ship before the hosted tier (INFRA-1337)

Building a hosted tier without a pricing hypothesis means shipping infrastructure
first and discovering willingness-to-pay after the invoice goes out. This document
inverts that: land a cheap fake-price-test landing page, measure Tier-2 checkout
conversion, and let the number decide whether the hosted tier is worth building at
its assumed price point.

---

## The 3 tiers

| Tier | Price | What's included | Who it's for |
|---|---|---|---|
| **Solo** | Free (OSS, self-hosted) | Full `chump` CLI, local `state.db`, self-managed NATS, unlimited local workers | Individual devs, small OSS maintainers — the current default user |
| **Team** | $29/seat/mo | Everything in Solo + hosted coordinator (managed `state.db` + dashboard), managed NATS cluster, cross-machine fleet sync, priority support | Small teams (2–20 devs) who want fleet coordination without running their own broker |
| **Enterprise** | $12,000/year (base, negotiable) | Everything in Team + air-gapped deployment option, SLA (99.5% coordinator uptime), SSO, dedicated Slack channel, custom onboarding | Orgs with compliance requirements or >20 devs |

Solo stays free and OSS indefinitely — see [LICENSE_STRATEGY.md](./LICENSE_STRATEGY.md).
Team and Enterprise are the two SKUs this experiment tests demand for.

---

## Anchor pricing benchmarks

Pulled from public pricing pages (2026-08 snapshot) to sanity-check Chump's
numbers against comparable dev-tool categories.

| Product | Category | Entry price | Notes |
|---|---|---|---|
| Sourcegraph Cody | AI code assistant, team tier | $19/seat/mo | Per-seat, targets teams already paying for Sourcegraph |
| Cursor | AI IDE, Pro tier | $20/seat/mo | Individual-first, team tier adds SSO/admin at $40/seat/mo |
| GitHub Copilot Business | AI coding assistant | $19/seat/mo | Widest-adopted per-seat anchor in this category |
| Vercel Team | Hosted infra coordination | $20/seat/mo (+usage) | Closest analog to "hosted coordinator" positioning |
| Linear | Team coordination SaaS | $8/seat/mo (Business tier) | Lower anchor — coordination-only, no compute |

**Read:** $19–20/seat/mo is the established anchor for "AI-assisted dev tooling,
per-seat, team tier." Chump's proposed $29/seat/mo sits above that anchor —
justified by Team including managed NATS + coordinator hosting (infra cost, not
just software), not just an AI feature bolted onto an IDE. If Tier-2 conversion
data (see Decision Rule below) comes back weak, the first lever to pull is
dropping to the $19–20 anchor before assuming the product itself doesn't have
demand.

---

## Per-seat vs. per-fleet: the decision

**Chosen: per-seat**, not per-fleet (i.e., not priced by worker count or gap
throughput).

Rationale:

- **Legibility.** A customer evaluating cost can count their own headcount.
  Per-fleet pricing (e.g., per-worker, per-gap-shipped) requires the customer to
  model Chump's own scaling internals before they can predict their bill —
  friction at the exact moment they're deciding whether to try it.
- **Matches the anchor set.** Every comparable in the benchmarks table above is
  per-seat. Deviating from the category norm adds an explanation tax to every
  sales conversation without a clear customer-side benefit.
- **Aligned incentive.** Per-fleet pricing would penalize customers for running
  more workers — the opposite of what a fleet-coordination product should
  reward. Per-seat charges for humans on the team, not for the machine work
  Chump exists to make cheap.
- **Known tradeoff, accepted.** A 3-person team running 50 workers pays the same
  as a 3-person team running 2. That's fine for V1 — fleet size at that scale is
  still small enough that infra cost doesn't swing the unit economics. Revisit
  if Enterprise usage patterns show heavy fleets dominating hosting cost
  disproportionate to seat count (candidate follow-up: usage-based overage on
  top of the per-seat base, not a full pricing-model swap).

Enterprise stays flat-rate/year rather than seat-multiplied because >20-seat
deals are negotiated individually anyway; a seat-multiplied number at that
scale is a starting point for negotiation, not the actual invoice.

---

## Decision rule

The experiment runs 2 landing-page variants (see below) driving traffic to a
Stripe checkout for the Team tier ($29/seat/mo, quantity selector defaulting to
1 seat). We are testing checkout-intent conversion, not completed payment —
the checkout session captures a real card but the experiment can be structured
as a $1 authorization-only hold if we want to avoid actually charging before
the hosted tier (INFRA-1337) exists to deliver against. That call is an
operator decision at experiment-launch time, not fixed by this doc.

| Tier-2 (Team) checkout conversion | Decision |
|---|---|
| **> 5%** | Ship the hosted tier (INFRA-1337) at this price point. Demand is validated. |
| **1–5%** | Iterate — try a lower price point ($19–20/seat, matching the anchor table) or clearer positioning before re-running the test. Do not ship the hosted tier on this data alone. |
| **< 1%** | Free-only forever. Do not build the hosted tier. Solo/OSS remains the only tier; revisit if the product's user base composition changes materially. |

Conversion = (checkout sessions started) / (unique landing page visitors), measured
per variant and pooled. Minimum sample size before reading the result: 200 unique
visitors per variant (avoids a single-digit-visitor false read in either
direction).

---

## Landing page variants

Two static HTML variants live in `docs/landing/pricing/`:

- [`variant-a-tiers.html`](../landing/pricing/variant-a-tiers.html) — leads with
  the full 3-tier comparison table above the fold. Bet: technical buyers want to
  see the whole decision space immediately and self-select.
- [`variant-b-single-offer.html`](../landing/pricing/variant-b-single-offer.html)
  — leads with a single Team-tier offer and price, tiers collapsed below a "see
  all tiers" toggle. Bet: a single clear CTA converts better than a comparison
  table that invites hesitation.

Both variants:

- Reuse the visual language of [`docs/landing/index.html`](../landing/index.html)
  (same font stack, color tokens, layout shell) so the pricing page reads as the
  same product, not a bolted-on marketing microsite.
- Point their primary CTA at a Stripe Checkout link (placeholder
  `STRIPE_CHECKOUT_URL_PLACEHOLDER` in both files — replace with the real
  Payment Link or Checkout Session URL at experiment-launch time).
- Include a `data-variant` attribute on `<body>` (`a` / `b`) so a simple
  pixel/analytics snippet can attribute conversion per variant without
  needing separate deploy paths.

---

## What this doc does not decide

- **Actual launch price.** $29/seat/mo and $12,000/year are the hypothesis being
  tested, not committed numbers. The decision rule above is what moves them.
- **Founding-customer mechanic.** Spec'd separately in
  [FOUNDING_CUSTOMER_OFFER.md](./FOUNDING_CUSTOMER_OFFER.md) (INFRA-1511) — that
  document is the validation-gate program (10 seats, 50% off, case-study rights)
  that runs *after* this pricing experiment gives a green light, not a substitute
  for it.
- **License terms.** Covered in [LICENSE_STRATEGY.md](./LICENSE_STRATEGY.md)
  (INFRA-1506) — this doc assumes Solo/OSS stays free regardless of which
  license path is chosen.
- **Stripe product/price object creation.** Follow-up implementation work once
  an operator approves running the experiment — not part of this design doc.
