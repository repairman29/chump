# Chump Pricing V1 — Experiment Design

> **Status: EXPERIMENT, not launched pricing.** This is the pricing surface for
> the Stripe-checkout fake-door test described below. Nothing here is billed
> until the hosted tier (INFRA-1337) actually ships. Founding-customer mechanic
> is spec'd separately in [`FOUNDING_CUSTOMER_OFFER.md`](./FOUNDING_CUSTOMER_OFFER.md)
> (INFRA-1511) and is the validation gate that runs *after* this experiment
> confirms there's a Team-tier market at all.

## Why 3 tiers, why now

Chump is OSS-first (self-coordinating fleet, proof on `repairman29/BEAST-MODE`
per `docs/MISSION.md`). The free tier is not a teaser — it's the actual
product for a solo dev running their own fleet on owned iron. The paid tiers
exist for the two things a solo setup structurally can't give you:
**someone else runs the coordinator for you** (Team), and **someone else
guarantees it stays up under contract** (Enterprise). That split maps directly
onto the two real costs of running a fleet coordinator: operational burden
(hosting/NATS/updates) and risk transfer (SLA, air-gap, support).

## The 3 tiers

| Tier | Price | Who it's for | What you get beyond OSS |
|---|---|---|---|
| **Solo** | Free, OSS (MIT/Apache-2.0 per [`LICENSE_STRATEGY.md`](./LICENSE_STRATEGY.md)) | Individual devs, small OSS maintainers, anyone willing to run their own coordinator | Full `chump` CLI, full fleet coordination, self-hosted NATS or none at all. No seat cap, no feature gate. |
| **Team** | $49/seat/mo (billed monthly, 5-seat minimum) | Small teams (3-20 devs) who want fleet coordination without running infra | Hosted coordinator (no server to babysit), managed NATS cluster, shared gap registry across the team, web dashboard, email support |
| **Enterprise** | $60,000/year (flat, not per-seat) | Orgs that need air-gapped deployment or contractual guarantees | Air-gapped / on-prem install, signed SLA (uptime + response-time), dedicated support channel, custom auth (SSO/SAML), procurement-friendly invoicing |

### Per-seat vs. per-fleet decision

**Team is per-seat. Enterprise is flat per-fleet.** Rationale:

- At Team scale (3-20 devs), seat count is the honest proxy for value received
  — more people coordinating work through the fleet = more value extracted.
  Per-seat billing is also what buyers in this segment already expect
  (every dev-tools SaaS in the benchmark table below does this).
- At Enterprise scale, seat-counting breaks down: the buyer isn't "20 more
  devs," it's "the whole org runs on this, and we need it to not go down."
  Enterprise deals are also negotiated, not self-serve — a flat number is
  easier to get through procurement than a seat estimate that changes
  every quarter. Air-gapped installs in particular often can't report
  seat counts back to us at all, so per-seat billing would be unenforceable
  there anyway.
- **Solo stays free at any seat count** because it's single-operator by
  construction (one person, one fleet, owned iron) — there's no meaningful
  "seat" to count.

## Anchor pricing benchmarks

Reference points used to sanity-check the Team-tier number ($49/seat/mo):

| Product | Entry paid tier | Notes |
|---|---|---|
| Sourcegraph Cody | $9/seat/mo (Pro), $19/seat/mo (Enterprise Starter) | Code-search + AI assist, not autonomous agents — floor comparison |
| Cursor | $20/seat/mo (Pro), $40/seat/mo (Business) | Closest product-shape comparison: AI-driven dev tool, per-seat, team tier above individual |
| GitHub Copilot Business | $19/seat/mo | Mass-market floor; single-feature (completions), not fleet coordination |
| GitHub Copilot Enterprise | $39/seat/mo | Closest "coordination + org features" comp at scale |
| Linear (Business plan) | $14/seat/mo | Non-AI comparison — coordination/workflow tooling without inference cost |

**Where $49/seat/mo lands:** above Cursor Business ($40) and Copilot Enterprise
($39), reflecting that Chump's hosted tier carries real inference + compute
cost per active fleet (LLM calls scale with gap throughput, not just seat
count) — this is infrastructure-plus-coordination, not a UI wrapper around
someone else's model calls. If the A/B test (below) shows resistance at $49,
the first lever to pull is *not* the sticker price — it's whether usage-based
overage (extra gaps/mo beyond a seat-included allotment) explains the
inference-cost coverage better than raising the flat per-seat number.

## The Stripe checkout experiment

We are not launching billing. We are testing **willingness to click "Subscribe"
at this price** using a fake-door landing page + real Stripe Checkout session
that captures payment intent and immediately full-refunds (or better: uses
Stripe Checkout in `payment_method_collection` mode without capturing — see
setup below) rather than actually charging.

**Two landing-page variants**, same 3-tier table, different framing on the
Team-tier CTA:

- **Variant A** — `docs/landing/pricing-variant-a.html` — leads with the
  free Solo tier and frames Team as "skip the ops work," emphasizing time
  saved. CTA: "Start hosted trial."
- **Variant B** — `docs/landing/pricing-variant-b.html` — leads with the
  Team tier directly (Solo mentioned but not first), frames it around team
  coordination outcomes ("stop losing track of who's doing what"). CTA:
  "Get team pricing."

Both variants point their Team-tier CTA at a Stripe Checkout Session for the
$49/seat/mo price. Route equal traffic to each (50/50) via whatever referral
link is used to drive people to `docs/landing/` — a query param
(`?variant=a` / `?variant=b`) is enough to attribute clicks; no server-side
split-testing infra needed for this experiment's scale.

**Stripe setup (fake-price-test, no real charge):**

```bash
# Create the test price (Team tier)
stripe prices create \
  --unit-amount 4900 \
  --currency usd \
  --recurring interval=month \
  --product-data name="Chump Team (pricing experiment)"

# Checkout Session in setup mode — collects payment method + confirms
# intent-to-buy WITHOUT creating a live subscription or charging the card.
stripe checkout sessions create \
  --mode setup \
  --payment-method-types card \
  --success-url "https://chump.dev/pricing-confirmed?session_id={CHECKOUT_SESSION_ID}" \
  --cancel-url "https://chump.dev/pricing"
```

Using `mode=setup` instead of `mode=subscription` means a completed checkout
is unambiguous signal ("this person got far enough to hand over a card") with
zero billing risk or refund cleanup — important for a pre-launch experiment
where the hosted tier doesn't exist yet to fulfill against.

**Tracking:** log `{variant, session_id, completed_at}` to
`docs/business/leads.csv` (same file/schema as the founding-customer funnel
in `FOUNDING_CUSTOMER_OFFER.md`) via the Stripe webhook
`checkout.session.completed`.

## Decision rule

Conversion = (completed Checkout Sessions) / (landing page visits that saw
the Team-tier CTA), measured per variant and pooled.

| Tier-2 (Team) conversion | Decision |
|---|---|
| **> 5%** | Ship the hosted tier (INFRA-1337). There's real willingness to pay at this price point; proceed to founding-customer mechanic (INFRA-1511) as the next validation gate before general availability. |
| **1% – 5%** | Iterate. Test a lower price point or a different framing (usage-based instead of flat per-seat) before committing engineering time to INFRA-1337. Re-run the experiment with the adjusted variant. |
| **< 1%** | Free-only forever. The market signal says the OSS Solo tier is the product; do not build hosted infrastructure nobody will pay for. Redirect effort to Solo-tier polish and OSS growth instead. |

Minimum sample size before trusting the result: 200 landing-page visits with
a visible Team-tier CTA (100 per variant), to avoid over-reacting to single-digit
click noise at this conversion range.

## Relationship to founding-customer mechanic

This pricing experiment answers "does anyone want to pay $49/seat/mo for a
hosted coordinator, at all." The founding-customer mechanic
([`FOUNDING_CUSTOMER_OFFER.md`](./FOUNDING_CUSTOMER_OFFER.md), INFRA-1511) is
the *next* gate — it only opens if this experiment clears the >5% bar, and it
answers a different, harder question: "will someone commit to 12 months and
let us publish their name." Running founding-customer outreach before this
experiment has a signal would be spending scarce goodwill (30 candidate teams,
one shot each) validating a price point instead of validating a customer
relationship.
