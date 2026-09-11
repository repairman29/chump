# CP-018: postsub Stripe fee structure vs BEAST-MODE 70/30 marketplace split — for Chump content-bots-suite monetization

**Target:** Chump's future `content-bots-suite` productization tier (INFRA-1850 umbrella, MISSION-010) — no billing/fee-split substrate exists today; this brief documents two candidate models before that workstream goes active.
**Arsenal match:** `repairman29/postsub/server.js` (fetched via `gh api repos/repairman29/postsub/contents/server.js`, 259 lines) for the Stripe fee-calc pattern; `repairman29/BEAST-MODE/docs/3_YEAR_VISION_AND_ROADMAP.md` for the 70/30 marketplace revenue-share model.
**Recommended route:** **Vendoring (deferred)** — `calculateFees()` is pure-function logic with no runtime state; port into a Rust crate (`chump-billing-feecalc`) when content-bots-suite becomes an active workstream, per INFRA-1850. This brief only documents; it does not implement.
**Status:** proposed (2026-09-11, INFRA-5879, slice of INFRA-1850).

## postsub: Stripe fee structure (verbatim from `server.js`)

Fetched fresh from `main` at time of writing. Reading it directly surfaces a discrepancy worth flagging: **the tier names/rates in this brief differ from what INFRA-1850's title/AC assumed** ("basic 5%, pro 8%, enterprise 3%"). The actual shipped constants are:

```js
// Fee calculation constants (server.js:8-9)
const STRIPE_FEE_PERCENTAGE = 0.029; // 2.9%
const STRIPE_FEE_FIXED = 30;         // 30 cents

// Platform fee percentages by plan (server.js:12-16)
const PLATFORM_FEES = {
  free: 0,
  professional: 0.05, // 5%
  enterprise: 0.03    // 3%
};
```

There is no `basic` tier and no `8%` rate anywhere in the file — the umbrella gap's assumed numbers do not match ground truth. Actual tiers are `free` (0%), `professional` (5%), `enterprise` (3%) — note `enterprise` is *cheaper* than `professional`, not a typo, presumably a volume-discount / negotiated-rate design choice.

**Fee/revenue split logic** (`server.js:19-37`, `calculateFees(amount, planId)`):

```js
const calculateFees = (amount, planId) => {
  const stripeFee = (amount * STRIPE_FEE_PERCENTAGE) + STRIPE_FEE_FIXED;
  const platformFee = amount * (PLATFORM_FEES[planId] || 0);
  const totalFees = stripeFee + platformFee;
  const creatorRevenue = amount - totalFees;
  // ... returns grossAmount, stripeFee, platformFee, totalFees, creatorRevenue, breakdown
};
```

Creator revenue = gross amount minus **two** deductions: the Stripe processing fee (2.9% + $0.30, standard Stripe card-processing pass-through) and a platform fee that scales *down* by tier as the creator's plan level goes up (`free`→`professional`→`enterprise` is 0%→5%→3%, i.e. paying for a plan buys a lower platform cut, not a higher one). Exposed via `POST /api/calculate-fees` and consumed internally by `GET /api/revenue-analytics/:customerId` (`server.js:189-250`), which aggregates `totalRevenue`, `totalPlatformFees`, `totalStripeFees`, `netRevenue`, and a mocked `churnRate`/`lifetimeValue`.

This is a **usage-metered, tier-discount model**: everyone pays Stripe's real processing cost, and the *platform's own* cut shrinks as the creator commits to a paid plan — the plan fee itself (not shown in this file, presumably a separate Stripe subscription price) is where postsub's own revenue actually comes from, and the platform-fee percentage is closer to a loyalty discount on marketplace take-rate than a primary revenue lever.

## BEAST-MODE: 70/30 marketplace revenue share

Found in `repairman29/BEAST-MODE/docs/3_YEAR_VISION_AND_ROADMAP.md` (line 175), under the Year-2 2027 "Q2 2027: AI Marketplace" roadmap section:

```
### Q2 2027: AI Marketplace
Priorities:
- Users can list custom models
- Revenue share model (70/30)
- Model versioning & A/B testing
- Federated learning
- $200K MRR target
```

No implementation exists yet in BEAST-MODE for this — it is a *roadmap intent*, not shipped code (unlike postsub's `calculateFees`, which is live and callable). The 70/30 split is the conventional flat-rate marketplace model: creator keeps 70%, platform keeps 30%, applied uniformly regardless of listing volume or tier. `lib/marketplace/plugin-marketplace.js` (the one marketplace file that *is* shipped in BEAST-MODE) tracks `totalRevenue`/`monthlyRevenue` and per-plugin `price * downloads`, but has no split constant wired in yet — the 70/30 number lives only in the roadmap doc, not in code.

## Comparison for Chump's content-bots-suite plan

| | postsub (tiered, shipped) | BEAST-MODE (flat 70/30, roadmap-only) |
|---|---|---|
| Take rate | 5% (professional) / 3% (enterprise) / 0% (free) — plus real Stripe pass-through (2.9%+$0.30) | Flat 30% platform / 70% creator |
| Incentive shape | Take rate *drops* as creator commits to a paid plan tier — rewards plan upgrades, not volume | Flat regardless of tier or volume — no upgrade incentive built into the split itself |
| Maturity | Live, callable, has an analytics rollup endpoint | Roadmap bullet only, no code |
| Fits Chump how | content-bots-suite gaps already carry a pillar tag + effort class (`xs/s/m/l`) — a tiered take-rate could map effort-class → fee-tier the way postsub maps plan → fee-tier | A flat 30% take is simpler to reason about and communicate, but gives Chump no lever to reward bot authors who ship in higher-effort/higher-pillar-value classes |

**Recommendation for INFRA-1850's eventual implementation:** the postsub tiered model is the better structural fit for Chump specifically *because* Chump already has a tier-like axis (pillar-tag × effort-class) that the flat BEAST-MODE model has no equivalent hook for — INFRA-1850's own AC #4 ("pillar-tag and effort-class map to fee-tier") only makes sense against a tiered model. Recommend vendoring postsub's `calculateFees` shape (tier→percentage map + Stripe pass-through as a separate deduction) rather than BEAST-MODE's flat 70/30, when the content-bots-suite workstream goes active. Correct the umbrella's assumed tier numbers (5%/8%/3% basic/pro/enterprise) to the verified ground truth (0%/5%/3% free/professional/enterprise) at that time.

## Why not now

Per INFRA-1850 AC: "Defer implementation until content-bots-suite is an active workstream — this gap parks the harvest target so when the productization moment comes, the prior art is referenced." This brief satisfies that parking function; `chump-billing-feecalc` crate scaffolding, tier-enum design, and the `scripts/ci/test-billing-feecalc.sh` smoke test remain open follow-up work for whichever gap activates the content-bots-suite billing substrate.
