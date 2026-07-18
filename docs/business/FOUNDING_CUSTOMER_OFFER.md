# Chump Founding Customer Offer

**Program:** 10 seats × 50% off × 12 months × signed case-study rights  
**Window:** Opens Friday of launch week — closes 14 days later (hard cap: 10 customers)  
**Goal:** Validate hosted-tier demand + generate 5+ named testimonials for launch (INFRA-1500)

---

## Terms Sheet

| Term | Detail |
|---|---|
| Seats | 10 total (first-come, first-served) |
| Discount | 50% off standard hosted-tier price for 12 months |
| Coupon | `FOUNDING50` — Stripe 12-month duration, quantity-limited price |
| Commitment | Monthly billing; cancel any time after month 3 |
| Case study | Signed rights to publish a 400–800 word case study + 1–2 pull quotes |
| Case study delivery | Customer reviews and approves draft before publication |
| Case study timing | Published no sooner than 60 days after onboarding |
| NDA option | Available on request; does not void case-study rights |
| Contact | jeff@chump.dev |

### What "50% off" means

Standard hosted-tier list price at launch will be announced separately. Founding
customers lock in 50% of that price for their first 12 months regardless of any
price changes during that window. After 12 months they move to the then-current
standard price, but can re-negotiate or cancel.

---

## One-Page Contract Template

> **Usage:** Send this as a PDF or DocuSign envelope. Fill in bracketed fields before sending.

---

**CHUMP FOUNDING CUSTOMER AGREEMENT**

Effective date: [DATE]

**Parties**

- Provider: [Chump / entity name], ("Chump")
- Customer: [COMPANY NAME], a [STATE] [corporation/LLC], ("Customer")

**1. Service**  
Chump grants Customer access to the Chump hosted multi-agent fleet coordinator
service ("Service") for [N] users for 12 months from the effective date.

**2. Pricing**  
Customer will be charged 50% of the then-published standard monthly rate for
the selected tier, for 12 calendar months from the effective date, via Stripe
coupon code `FOUNDING50`. After 12 months, Customer will be moved to
standard pricing with 30 days' advance notice.

**3. Case Study Rights**  
Customer grants Chump a non-exclusive, perpetual license to publish one case
study (400–800 words) and up to two attributed pull quotes describing Customer's
experience with the Service. Customer retains approval rights over the final
draft before publication. Publication will occur no earlier than 60 days after
the effective date.

**4. Confidentiality**  
Neither party will disclose the other's non-public technical or business
information to third parties without written consent. This clause does not
restrict the case study content approved under Section 3.

**5. Limitation of Liability**  
Chump's liability arising out of this agreement is limited to the amounts paid
by Customer in the 3 months preceding the claim.

**6. Term and Termination**  
This agreement is month-to-month after month 3. Either party may terminate with
30 days' written notice. Early cancellation in months 1–3 requires payment of
the remaining month-3 balance.

**7. Governing Law**  
[State], USA.

---

Signatures:

Chump: _________________________ Date: _________

Customer: ______________________ Date: _________

Name/Title: ___________________________________

---

## Case Study Release Form

> **Usage:** Attach to or reference in Section 3 of the contract. Stand-alone version for
> customers who signed a generic SaaS agreement.

---

**CHUMP CASE STUDY RELEASE FORM**

Customer: [COMPANY NAME]  
Signatory: [NAME, TITLE]  
Date: [DATE]

**Grant of Rights**  
I authorize Chump to publish a written case study and attributed quotations
describing [COMPANY NAME]'s use of the Chump fleet coordinator. I understand:

1. I will receive a draft for review and approval before publication.
2. I may request factual corrections; I may not veto positive but accurate descriptions.
3. My company name and logo may appear alongside the case study on chump.dev and in marketing materials.
4. This release is non-exclusive; I retain the right to tell my own story.
5. I may revoke permission for future use at any time; previously published content remains.

Signed: _________________________________  
Name/Title: ______________________________  
Date: ___________________________________

---

## Stripe Configuration

### Coupon: FOUNDING50

| Field | Value |
|---|---|
| Coupon ID | `FOUNDING50` |
| Type | Percentage |
| Percent off | 50% |
| Duration | `repeating` |
| Duration in months | 12 |
| Max redemptions | 10 |
| Applies to | Hosted-tier monthly price |

**Stripe Dashboard path:**  
Billing → Coupons → Create coupon → set fields above.

**CLI equivalent (for reproducibility):**
```bash
stripe coupons create \
  --id FOUNDING50 \
  --percent-off 50 \
  --duration repeating \
  --duration-in-months 12 \
  --max-redemptions 10
```

### Quantity-Limited Price (10-customer cap)

Create a Stripe Price with `usage_type=licensed` and set the Product's inventory
to 10 units, or use Stripe's customer portal to track redemptions manually against
the 10-seat cap. When the coupon's `max_redemptions` reaches 10, Stripe automatically
blocks further redemptions — no additional enforcement needed.

**Verify cap:**
```bash
stripe coupons retrieve FOUNDING50 | jq '.times_redeemed, .max_redemptions'
```

---

## Outreach List — 30 Candidate Teams

Criteria: small OSS projects or dev-tools companies with active backlogs, no existing
AI-automation budget, friendly to early adopters.

| # | Team / Project | Why They Fit | Contact Path |
|---|---|---|---|
| 1 | Zellij (terminal multiplexer) | Active Rust OSS, big backlog, single maintainer | GitHub Discussions |
| 2 | Helix editor | ~200 open issues, small core team, no automation | GitHub Issues / Discord |
| 3 | Broot (file navigator) | Sole maintainer with large issue queue | GitHub / maintainer email |
| 4 | Lapce editor | Rust, editor team, open roadmap | Discord |
| 5 | Gitoxide | Pure-Rust git, many open tasks, 1 lead author | GitHub |
| 6 | Millet (LSP) | Small Rust tool, 1-2 devs | GitHub |
| 7 | fd-find | Active CLI OSS, small team | GitHub |
| 8 | bottom (btm) | System monitor, small team, many open PRs | GitHub |
| 9 | bat (cat clone) | Many open issues, small core | GitHub |
| 10 | Starship prompt | Large backlog, community driven | Discord / GitHub |
| 11 | Atuin (shell history) | Growing project, 2-3 core devs | Discord |
| 12 | navi (cheatsheet) | 1 maintainer, stale PRs | GitHub |
| 13 | xplr (file manager) | Active OSS, Lua plugin system, backlog | GitHub / Discord |
| 14 | yazi (file manager) | Rust, active dev, many feature requests | GitHub |
| 15 | Carapace-bin | Multi-shell completions, >1k open items | GitHub |
| 16 | Wezterm | Active Rust terminal, solo lead author | GitHub / Discord |
| 17 | Ghostty | New terminal, growing backlog | Discord |
| 18 | Mise (tool version mgr) | Rust, jdx is responsive, open roadmap | GitHub |
| 19 | Pixi (conda-style) | Rust, growing team, feature-heavy roadmap | GitHub |
| 20 | Rye (Python mgr) | Armin Ronacher, small team, open roadmap | GitHub Discussions |
| 21 | uv (Astral) | Fast Python tooling, Rust, active OSS | GitHub |
| 22 | Ruff linter | Rust, Charlie Marsh team, large issue backlog | GitHub / Discord |
| 23 | Oxc (JS toolchain) | Rust, boss+ team, Oxford CS focus | GitHub / Discord |
| 24 | Biome (fmt/lint) | Multi-file Rust OSS, committee driven | GitHub / Discord |
| 25 | Turborepo | Vercel team, active monorepo tooling | GitHub |
| 26 | Moon (task runner) | Rust build, small company, open roadmap | Discord |
| 27 | Nextest (test runner) | Rust, 1 lead dev (Rain), active backlog | GitHub |
| 28 | cargo-dist | Axo team, Rust release tooling | Discord |
| 29 | Shuttle (Rust hosting) | Active OSS PaaS, team of ~5 | Discord / GitHub |
| 30 | Loco (Rust web) | Rails-inspired Rust, growing community | GitHub / Discord |

**Prioritization:** rows 1–15 are solo/2-person maintainers — highest pain, lowest
barrier. Rows 16–30 are small teams where one motivated dev can unblock the purchase.

**Outreach script template** (adapt per project):

> Hi [name] — I maintain Chump, a multi-agent fleet coordinator for Rust (and any
> language) codebases. It autonomously picks tasks from a queue and ships them as
> merged PRs — no per-step review. You file the gap, agents do the work.
>
> We're opening 10 founding-customer slots at 50% off for the first year in exchange
> for a short case study. Given your open [issue / PR] backlog I think it could
> meaningfully reduce your maintenance load. Happy to give you a 30-minute live demo
> on your repo. Interested?

---

## Conversion Tracking

### Funnel stages

| Stage | Event | Tracked in |
|---|---|---|
| Capture | Email submitted on landing page | Signup webhook → `docs/business/leads.csv` |
| Qualified | Email confirmed + demo requested | Manual tag in leads sheet |
| Demo held | Demo completed | Manual update |
| Offer extended | Contract sent | Manual update |
| Signed | Contract returned | Manual update + Stripe coupon redeemed |
| Onboarded | First `chump claim` under their account | Stripe subscription active |
| Quote delivered | Case study draft sent | Manual update |

### leads.csv schema

```
email,name,company,project_url,stage,source,created_at,notes
```

**File location:** `docs/business/leads.csv` (gitignored — do not commit PII to main).

Add to `.gitignore`:
```
docs/business/leads.csv
docs/business/contracts/
```

### Conversion rate target

- Capture → Demo: 30%
- Demo → Signed: 40%
- Signed → Case study delivered: 80%

At 30 outreach contacts → ~9 demos → ~4 signed → 4 case studies.
With landing page capture as parallel channel, target 5+ case studies for launch.

### Weekly tracking query

```bash
# Count by stage
awk -F',' 'NR>1 {print $5}' docs/business/leads.csv | sort | uniq -c | sort -rn
```

### Stripe redemption check

```bash
stripe coupons retrieve FOUNDING50 --api-key $STRIPE_SECRET_KEY \
  | jq '{redeemed: .times_redeemed, remaining: (.max_redemptions - .times_redeemed)}'
```
