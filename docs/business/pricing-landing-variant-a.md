# Pricing Landing Page — Variant A: "Autonomy" Framing

**Test variable:** hero/copy angle. Pricing table and Stripe Checkout flow are
identical to Variant B — see [`PRICING_V1.md`](./PRICING_V1.md) Section 2 for
the test design this variant is one arm of.

**Audience hypothesis:** developers and tech leads already sold on agentic
coding, who need to see the *ceiling* of autonomy Chump reaches (a fleet
shipping PRs unattended) before price becomes the deciding factor.

---

## Hero section

**Headline:** Ship while you sleep.

**Subhead:** Chump runs a fleet of coding agents that claim work, write code,
open PRs, and merge — autonomously, 24/7. You review outcomes, not diffs.

**CTA button:** Start free (Solo) · See Team pricing

---

## Section 2 — "What autonomy actually looks like"

- A fleet, not a single assistant — multiple agents work independent gaps in
  parallel, coordinated without you in the loop.
- Claim → code → ship, unattended — the loop includes CI, review-gate checks,
  and auto-merge, not just code generation.
- You set the guardrails once — acceptance criteria, priority, domain — and the
  fleet picks up work against them continuously.

## Section 3 — Pricing table

*(renders the Section 1 table from PRICING_V1.md verbatim — Solo/Team/Enterprise,
same three rows, same prices)*

Sub-copy under the Team row: **"Most teams start here once Solo's autonomy loop
proves itself on one repo."**

## Section 4 — Social proof placeholder

*(reserved for founding-customer case studies once INFRA-1511 produces them —
empty at test-launch time, not fabricated)*

## Section 5 — FAQ

- **Does the fleet ever touch main without review?** No — every merge goes
  through PR + CI gates; autonomy means unattended work, not unreviewed work.
- **What happens if an agent gets stuck?** Self-healing rescue loops unstick
  most cases; anything that can't self-resolve pages a human.
- **Can I self-host Team-tier features?** Team's hosted-coordinator + managed-NATS
  convenience is what you're paying for — self-hosting everything is what Solo
  (free) already gives you.

## Checkout CTA (bottom of page)

**Button:** Get Team pricing → Stripe Checkout (test mode, see PRICING_V1.md §4
for the no-charge / waitlist mechanic)
