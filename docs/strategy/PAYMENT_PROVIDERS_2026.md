# Payment Providers Spike — Stripe vs Lemon Squeezy vs Paddle (2026)

**Status:** research only, no provider chosen. INFRA-1510.
**Scope:** first-pass evaluation to unblock any future monetization decision.
Cross-links: MEMORY `exec_summary_hardware_economics` (cost model this revenue
has to cover) and `project_offline_local_llm_mission` (any pricing here must
leave the free-offline-tier viable — this spike does not touch that tradeoff,
it only evaluates *how money moves*, not *how much to charge*).

This is not a recommendation. It's the input a recommendation would need.

## Comparison table

| Dimension | Stripe | Lemon Squeezy | Paddle |
|---|---|---|---|
| MoR status | **No** (Stripe Tax is an add-on calc/remit tool; *you* are the seller of record) | **Yes** — MoR for all sales | **Yes** — MoR for all sales |
| Fee at <$100/mo MRR | 2.9% + $0.30/txn (US card) | 5% + $0.50/txn | 5% + $0.50/txn (Paddle Billing standard) |
| Dev/CLI experience | Best-in-class: `stripe` CLI, webhook forwarding/replay, strong typed SDKs, huge community | Good: simple REST API + webhooks, hosted checkout, less tooling depth | Good: REST API + webhooks, Paddle.js overlay checkout, decent docs, smaller community |
| Self-hosted-friendliness | Needs a backend to hold the secret key and create charges/webhooks server-side; works fine from a home server, no forced SaaS middleman | Same shape — webhooks + API key from your own box; checkout itself is hosted by LS so less PCI surface for you | Same shape — webhooks + API key; checkout overlay is hosted by Paddle |
| Chargeback risk model | You own disputes directly; ~$15 dispute fee, you supply evidence, you eat losses if you lose | LS owns disputes as MoR (they're the merchant of record on the card statement); dispute friction is largely theirs, but expect them to pass cost/risk signals to your account standing | Paddle owns disputes as MoR similarly; also known for stricter underwriting on some business categories (can reject/close accounts it judges high-risk) |

## Stripe

Stripe is not a Merchant of Record. When a customer's card statement shows a
charge, it shows *your* business, not Stripe's — Stripe is a payment
processor and (optionally) a tax-calculation/remittance tool via Stripe Tax,
not the entity legally selling the good. That means **you** register for
sales-tax/VAT permits in every jurisdiction where you cross an economic
nexus threshold, file returns, and remit the money. For a one-person shop
without an accountant, this is the deal-breaker line item: US economic
nexus alone spans 45 states with different thresholds and filing cadences,
and EU/UK VAT registration for digital goods is a separate non-trivial
process (OSS/MOSS schemes reduce but don't eliminate the burden). Fee-wise
Stripe is the cheapest of the three at low volume (2.9% + $0.30 vs 5% +
$0.50 for the MoR options), and that gap compounds if volume grows, but the
"cheaper fee, more back-office liability" tradeoff is exactly what MoR
providers exist to avoid.

Where Stripe wins decisively is developer experience and metered/usage
billing. The `stripe` CLI supports local webhook forwarding and event replay,
which matters for a self-hosted/local-first stack — you can develop and test
the entire billing flow against a real Stripe test-mode account without
exposing a public endpoint. Stripe Billing's meter/usage-record APIs are the
most mature of the three for anything resembling "bill per unit of fleet
work performed," which is directly relevant if a future product bills
metered compute or agent-hours. Chargebacks are yours to fight: Stripe
charges a flat dispute fee (refunded if you win) and gives you an evidence
API, but the liability and reputational risk of a rising dispute rate sit on
your account, not a MoR's.

**Fee page:** https://stripe.com/pricing
**Tax/MoR positioning:** https://stripe.com/tax (explicitly framed as "calculate and collect," not "we are the seller")
**Deal-breaker:** not MoR — multi-jurisdiction tax registration/remittance is a non-starter for a solo operator without an accountant, at least for the launch/validation phase.

## Lemon Squeezy

Lemon Squeezy is a Merchant of Record: it is the legal seller on every
transaction, which means it calculates, collects, and remits sales tax and
VAT globally on your behalf. For a one-person operation this collapses the
single biggest operational risk of accepting international payments — no
tax registration, no jurisdiction-by-jurisdiction filing, no VAT-MOSS
paperwork. The cost of that is baked into the fee: 5% + $0.50 per
transaction, roughly 1.7-2x Stripe's rate at low volume. Lemon Squeezy also
ships first-class license-key generation and management as a product
feature (not a bolt-on), which fits a one-time-license sale model unusually
well — you can gate a downloadable binary or activation flow off an LS
license key with minimal glue code. It was acquired by Stripe in 2024 but
as of this writing continues operating as a distinct product with its own
dashboard, API, and checkout, rather than being folded into Stripe's core
product surface.

Self-hosted-friendliness is solid: your server holds an API key, receives
webhooks (`order_created`, `subscription_payment_success`, etc.), and never
needs to touch card data directly since checkout is hosted by LS. Developer
experience is good but noticeably thinner than Stripe's — a straightforward
REST API and webhook set, no dedicated local-dev CLI/webhook-forwarding
tooling equivalent to `stripe listen`. Chargeback risk is mostly LS's
problem structurally (they're the merchant of record contesting the
dispute), but a high dispute rate on your storefront can still affect your
standing with them, and payout holds are a known pattern for MoR platforms
when risk signals spike. No public deal-breaker beyond the fee premium and
the fact that a newer/smaller platform carries more platform-risk
(pricing/policy changes, acquisition-driven roadmap shifts) than an
incumbent like Stripe.

**Fee page:** https://www.lemonsqueezy.com/pricing
**MoR/tax positioning:** https://www.lemonsqueezy.com/tax-anxiety-relief (explicitly markets itself as "we handle global sales tax so you don't have to")
**Deal-breaker:** none structural — the tradeoff is fee premium in exchange for zero tax-compliance burden, which for a solo operator is likely a net win, not a blocker.

## Paddle

Paddle occupies the same MoR category as Lemon Squeezy — it is the legal
seller of record and handles global sales tax/VAT calculation, collection,
and remittance — but is positioned more toward SaaS subscription businesses
than one-time indie-license sales, with Paddle Billing offering more mature
subscription lifecycle tooling (proration, plan changes, dunning,
usage-based add-ons) than Lemon Squeezy's feature set. Fees are in the same
band as Lemon Squeezy (roughly 5% + $0.50 standard, with some regional
variation), so there's no cost advantage either direction between the two
MoR options — the choice between them is about product fit (subscription
lifecycle depth vs. license-key/one-time-purchase simplicity) rather than
price.

Developer experience is decent: a REST API, webhooks, and a JS overlay
checkout (Paddle.js) that can be embedded without redirecting the user off
your site, which Lemon Squeezy's more redirect-heavy hosted checkout doesn't
match as closely. Self-hosted-friendliness is comparable to Lemon Squeezy —
API key + webhooks from your own server, checkout UI hosted by Paddle so no
direct PCI surface for you. The notable deal-breaker-adjacent risk with
Paddle specifically is underwriting strictness: Paddle has a documented
history of being more conservative about which business categories and
product types it will onboard or continue serving as MoR, including account
reviews/holds triggered by risk signals (chargeback rate, refund rate,
sudden volume spikes) — a real consideration for a pre-revenue solo product
without an established track record.

**Fee page:** https://www.paddle.com/pricing
**MoR/tax positioning:** https://www.paddle.com/legal/merchant-of-record (explicit MoR/tax page)
**Deal-breaker:** underwriting risk — Paddle's MoR-driven account review process is stricter than Lemon Squeezy's for new/unproven sellers, which matters more before there's a payment history to point to.

## Decision matrix

This is a matrix for *which provider fits which product shape*, not a
recommendation for overall pricing strategy.

| Product | Best fit | Why |
|---|---|---|
| One-time license (e.g. a downloadable binary/activation key) | **Lemon Squeezy** | Built-in license-key issuance/validation, MoR removes tax paperwork for a single-purchase flow, fee premium matters less on a higher one-time price point |
| Monthly subscription (SaaS-style recurring) | **Paddle** (if global from day one) or **Stripe Billing** (if US-only and willing to own tax compliance) | Paddle's subscription lifecycle tooling (dunning, proration, plan changes) is more mature than Lemon Squeezy's; Stripe wins if tax scope is deliberately constrained to reduce the fee burden |
| Fleet metered/usage billing (pay-per-agent-hour or per-unit-of-work) | **Stripe** | Only one of the three with mature usage-record/meter APIs; MoR options' usage-billing support is comparatively immature as of this writing |

## Operator-facing summary: 3 things to decide before picking

1. **Do we want Merchant-of-Record protection, or are we willing to own tax
   compliance ourselves?** MoR (Lemon Squeezy/Paddle) costs ~2x the
   per-transaction fee but eliminates sales-tax/VAT registration and filing
   across every jurisdiction we sell into. Non-MoR (Stripe) is cheaper per
   transaction but means *we* (a one-person shop, no accountant) are on the
   hook for tax compliance the moment we cross a nexus threshold anywhere.
2. **Are we OK launching US-only, or do we need global payments from day
   one?** US-only dramatically shrinks the tax-compliance surface even on
   Stripe (one country's economic-nexus rules instead of every country's
   VAT regime), which could make Stripe viable at launch even without MoR
   protection, deferring the MoR decision until international demand shows
   up.
3. **What's our refund policy?** Chargeback/refund handling differs
   structurally by provider (we own disputes on Stripe; the MoR platform
   owns them on Lemon Squeezy/Paddle) — a clear, published refund policy
   reduces dispute volume regardless of provider, and provider choice
   should not substitute for having one.

## Operator action items (tracked outside this gap registry)

The following require operator sign-off / legal-adjacent input and are
**not tracked as gaps here** per AC #6 — they belong in
`chump-proprietary/OPERATOR_ACTIONS.md` (a private sibling repo not present
in this worktree; add them there directly):

- Decide MoR vs non-MoR (see summary item 1 above) — operator judgment call,
  not an engineering decision.
- Decide US-only vs global launch scope (summary item 2).
- Draft and publish a refund policy (summary item 3) — may need light legal
  review depending on jurisdiction.
- If Stripe is chosen: register for sales-tax permits in any jurisdiction
  crossing economic nexus, before first sale in that jurisdiction.
- If Lemon Squeezy or Paddle is chosen: complete their MoR onboarding /
  underwriting review before going live — do not assume same-day approval.

## Explicitly out of scope

No integration code was written for this spike. Implementation (SDK
wiring, webhook handlers, checkout flow) is a follow-up gap once a provider
is chosen. No provider is chosen in this gap.
