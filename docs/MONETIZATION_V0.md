# Monetization v0 — Hypothesis, Not Business Plan

**Version:** 2026-04-24 (PRODUCT-019)
**Status:** Pre-revenue. Prototype-stage. Zero paying users, zero inbound enterprise.
**Scope:** Enumerate commercial options, pick top 2 to stress-test, write down what would prove each bet wrong.

> **Framing.** Chump is a prototype. We are not selling it yet — activation funnel (PRODUCT-015) hasn't hit the CPO threshold, research credibility (Tier 4 panel) is gated on that funnel, and we have no outside validation that anyone wants to pay for this. This doc is a *hypothesis doc*: what commercial direction should we test first, and what cheap experiment would kill each hypothesis? The CPO (founder) picks the top 2 after reading. **Kill criteria matter more than revenue projections.** If we can't write down what would falsify a bet, we don't understand the bet well enough to run it.

---

## Options enumerated

All six options Chump could plausibly monetize (or defer) under:

| # | Option | One-line bet | Cheap to test? |
|---|---|---|---|
| **A** | **OSS-core + enterprise support contracts** | Teams run Chump self-hosted; pay for SLA support, private patches, and integration help. | **Yes** — launch OSS publicly, see if inbound comes. <$1K. |
| **B** | **Usage-based hosted Pixel-mesh** | Sell fleet-as-a-service: managed Pi/Pixel nodes running Chump + local models, metered by inference-hour. | **No** — needs hardware, deployment infra, billing. $20K+ minimum. |
| **C** | **Hosted multi-agent coordination (Chump-as-Claude-Code-fleet)** | Teams rent a managed multi-agent worktree dispatcher; pay per concurrent agent-hour. Bring-your-own-API-keys. | **Partially** — needs auth + billing + a cloud deployment. $5K–10K. |
| **D** | **Commercial eval API (sell the methodology/harness)** | License the Chump eval harness (task-class gating, LLM-as-judge κ, preregistration discipline) to teams shipping agents. | **Yes** — publish methodology paper + SaaS dashboard MVP. <$3K. |
| **E** | **Research licensing (dual-license for commercial use)** | Current MIT → AGPL-or-commercial dual license; enterprise pays for non-copyleft terms. | **Yes** — the license change itself is free, signal detection is slow (6–12 mo). |
| **F** | **Defer all commercial decisions** | Stay OSS, focus on research credibility + product activation, revisit in 6–12 months. | **Yes** — no spend, but opportunity cost if a wedge actually exists. |

---

## Picks

We test **A (OSS-core + support)** and **D (commercial eval API)** first. Both are cheap, both exploit parts of Chump where we already have output (working self-hosted agent; working eval harness with preregistration + Wilson CIs + judge-κ machinery that most agent shops *don't* have). Both can be validated or killed in <2 weeks and <$5K without committing to infrastructure buildout.

**Rejected now, not forever:**
- **B (Pixel-mesh)** — too expensive to test pre-activation. Revisit after FLEET-* ships and we have >1 non-Jeff node running Chump.
- **C (hosted coordination)** — plausible but premature; test after activation funnel shows ≥10 non-Jeff humans sticking around. The wedge is real (Claude Code fleet is novel) but we'd be selling infra on top of a product nobody activates on yet.
- **E (dual-license flip)** — reversible harm: flipping MIT → AGPL would scare off the OSS contributors we don't yet have. Revisit only after (A) validates inbound enterprise signal.

**F (defer) is also a pick** — see below.

---

## Pick 1 — OSS-core + enterprise support contracts

- **The bet.** Ship Chump publicly on GitHub with polish; teams that run self-hosted agents on consumer hardware will surface via GitHub stars / issues / inbound email, and a fraction will pay for support, custom patches, or integration help.
- **Smallest testable slice.**
  - Land Product Gates G1+G2+G3 (install, demo, activation funnel — already in roadmap).
  - Public GitHub launch with a clear README wedge line, demo video, and a `SUPPORT.md` that names a price ($2K–5K/mo for 4h response SLA, first month free for design-partners).
  - One HN / Show HN post + one AI-tools Discord drop.
  - Instrument: count (a) GitHub stars, (b) inbound support inquiries, (c) non-Jeff installs from telemetry.
  - Cost: ~1 week of Jeff + <$500 infra. Well under $5K.
- **Kill criterion.**
  - **Zero inbound enterprise-flavored inquiries after 90 days** of public launch with Product Gates passing. "Enterprise-flavored" = email from a work domain asking about support, SLA, private deployment, or custom features. GitHub drive-by issues don't count.
  - *AND* fewer than **25 non-Jeff installs** via telemetry over the same window.
  - If both hit, OSS-core + support has no demand signal at prototype scale and we move Chump to pure-research / personal-tool mode.
- **Unit-economics sketch** (order of magnitude only).
  - Contract size: $2K–5K/mo retainer, expect 10–50h/mo of Jeff time.
  - COGS: Jeff's time (the scarce input) + ~$50/mo hosting for a status page and CI runners on their behalf. Call it $2K/mo COGS at Jeff's blended rate if we're honest.
  - Margin: thin — this is a **signal** bet, not a margin bet. One $3K/mo contract = validation. Three = a part-time business. Ten = hire a second engineer.
  - Break-even to quit-day-job: ~5–8 concurrent retainers. **Not the goal yet.** Goal is 1 paying design-partner in 90 days.
- **Dependencies.**
  - PRODUCT-015 (activation funnel) live.
  - PRODUCT-016 (3-min demo) recorded.
  - PRODUCT-017 (clean-machine install re-verified).
  - Public GitHub repo launch (currently private-feeling; org is `repairman29/chump`).
  - `SUPPORT.md` + pricing page.
  - A working email / Discord inbound channel that isn't Jeff's personal inbox.

---

## Pick 2 — Commercial eval API (sell the methodology/harness)

- **The bet.** Agent teams (Cursor, Cline, Aider-likes, enterprise RAG shops) ship without the eval rigor Chump has stumbled into — Wilson CIs, A/A controls, task-class gating, preregistration, judge-κ. They'd pay for a hosted eval service ("upload your agent + task fixtures, get a statistically-defensible scorecard") or a methodology license.
- **Smallest testable slice.**
  - Publish the eval methodology as a standalone post — preregistration template, judge-κ recipe, task-class gating, A/A baseline — with the Chump numbers as worked examples.
  - Build a one-page "Eval-as-a-Service" landing page that takes email signups and describes the offering (not yet built): "Upload your agent, get a scorecard with Wilson CIs and judge-κ in 48h. $2K/run, free for design-partners."
  - Drop the post in ML Twitter, r/LocalLLaMA, two AI-eval Discords.
  - Instrument: email signups, DMs, "can you run this on our agent?" inbound.
  - Cost: ~1 week of Jeff writing + <$200 landing page + <$50 ad spend. Well under $5K.
- **Kill criterion.**
  - **Zero "can you eval our agent?" inbound after 60 days** of the methodology post being live.
  - *AND* fewer than **50 email signups** on the landing page over the same window.
  - *AND* fewer than **5 academic citations or blog citations** of the methodology post.
  - If all three hit, nobody wants to pay for eval rigor yet — either they don't value it, or they DIY it. Shelve and revisit post-activation.
- **Unit-economics sketch** (order of magnitude only).
  - Per-eval-run price: $2K (first batch), $500–1K steady state.
  - COGS: compute for running the eval (~$50–200 in API calls if eval uses cloud models; ~$5 on local) + ~4–8h of Jeff adjudicating contested cases.
  - Margin: healthy — 70–80% gross at steady state if Jeff-time amortizes across customers. **This is a margin bet**, unlike Pick 1.
  - Scale ceiling without hire: ~4–8 evals/month at Jeff's capacity. Beyond that needs tooling (self-serve upload, automated κ computation, dashboard).
  - The *bigger* prize is methodology licensing (enterprise pays $10K–50K/yr for the harness + private-deployment rights + training) — but that's Phase 2 after one paid eval lands.
- **Dependencies.**
  - Preregistration audit stable (EVAL-077-style tooling, even if deferred).
  - Methodology post written — draws on RESEARCH_INTEGRITY.md, EVAL-025/027c/030, and the existing `docs/eval/` structure.
  - A landing page (can live at `chump.dev/eval` or equivalent — doesn't need to be on the Chump GitHub).
  - Enough of the harness genuinely works end-to-end that we could run a real customer's agent on it without embarrassment (today: probably yes for CLI agents, shaky for anything else).

---

## Pick 3 (third option) — Defer all commercial decisions

Treated as a pick, not a fallback. "Do nothing commercial for 6–12 months" is a *decision* with an expected value, not an absence of one.

- **The bet.** Chump's best move right now is research credibility + activation — commercial attempts before either of those is real will produce noise that distracts from the work that actually sets valuation later.
- **Smallest testable slice.** No slice needed; the action is *not acting*.
- **Kill criterion** (what would make us stop deferring):
  - A credible acquirer reaches out with a real conversation (not a cold "how much for the repo" email — actual due diligence interest).
  - *OR* we hit **10K GitHub stars** (signal that public-demand exists even without us marketing).
  - *OR* Pick 1 or Pick 2's landing pages get >100 signups in 30 days (strong-enough pull to justify sales effort).
  - *OR* Product Gates G1+G2+G3 pass AND activation funnel shows >50 non-Jeff humans sustained for 90 days — the wedge is validated, it's time to monetize.
  - Absent those: keep deferring.
- **Unit-economics sketch.** Zero revenue, zero COGS. The cost is **opportunity cost** — if a wedge exists and we ignored it, valuation later is lower. The benefit is focus: every hour on monetization is an hour not on research or product, both of which are the actual scarce inputs.
- **Dependencies.** None. This is the free action.

---

## Why these picks and not the others, briefly

- **Picks A + D share a property:** both are validatable by *writing and publishing*, not by *building infrastructure*. A README + SUPPORT.md + one post is the MVP. If nothing happens, we've learned something for <$1K. That's the right risk profile for a prototype with no activation signal yet.
- **Pick F (defer)** runs in parallel — we aren't putting weight on A or D until their kill criteria trigger or their cheap tests come back positive. Between now and then, defer is the dominant strategy.
- **B and C need infrastructure before they can be tested** — and infrastructure built against an unvalidated wedge is the classic prototype-stage failure mode. Revisit after Pick 1 shows signal.
- **E (dual-license)** has an asymmetric downside (scaring off OSS contributors we'd need for A) and no upside until A has proven there's enterprise demand to convert. Don't flip the license until someone has asked us to.

---

## What this doc is NOT

- Not a revenue projection — no "$X ARR by Qn" table on purpose. Kill criteria, not forecasts.
- Not a GTM plan — Picks A and D each get a single-slice test. GTM planning happens only after a test comes back positive.
- Not a pricing commitment — the $2K/mo, $2K/run, $10K/yr numbers are order-of-magnitude anchors for the unit-economics sketch, not list prices.
- Not a commitment to monetize — F is a real option and is currently the front-runner.

---

## Revisit cadence

**Per Red Letter cycle.** Each Red Letter synthesis reviews: (1) has any kill criterion triggered? (2) has any cheap test shown signal? (3) should the top-2 picks change? If no change for three consecutive cycles and no signal, the founder reconsiders whether Chump should be a business at all vs. a personal research tool.

---

## Document history

- 2026-04-24: v0 — enumerated 6 options, picked A + D to test + F as null-option, each with bet / slice / kill / economics / deps. No revenue projections by design.
