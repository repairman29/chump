# Chump Project: Expert Review Panel

**Document Purpose:** Define the expert panel needed for a thorough top-to-bottom evaluation of Chump before external launch or major funding. Use this to source reviewers, scope engagements, and track findings.

**Version:** 2026-04-24 (rev. CPO-reframe + AI-substitution pass)
**Status:** Product-gated — research reviews deferred until activation funnel proves signal
**Est. Timeline:** Product gates ~1–4 weeks (in-house); reviews afterward 4–6 weeks (parallel)
**Est. Budget:** $6K–20K (product-first tiers); comprehensive $20K–30K *only* post-activation-signal

> **CPO reframe (this revision).** A research-credibility panel is
> vanity spend if nobody can install the product and complete a first
> task. Red Letter flagged zero product velocity for two cycles. Until
> PRODUCT-015 (activation funnel) shows that users install, activate,
> and return at a threshold set by the CPO, **we do not commission
> paid external research reviewers.** The panel below is reordered
> product-first: product/UX/GTM seats lead, research seats are
> gated and reduced from 3 to 1 combined seat. See the **Product
> Gates** section below.
>
> **AI-first principle (also this revision).** Roughly 55–60% of the
> review work below is mechanical: static analysis, statistical
> checks, license scanning, benchmark harnesses, link-rot,
> preregistration diffing, threat enumeration, onboarding simulation.
> All of that can run as dispatched Claude agents + OSS tooling before
> a single human expert is engaged. Humans should only be paid for
> judgement calls a model cannot credibly sign off on: market
> intuition, credentialed research validation, safety sign-off,
> hands-on hardware. See the **AI vs Human Matrix** section — it
> replaces flat spend with a tiered pipeline (AI pass → narrow-scope
> human audit) and typically cuts panel cost 60–70%.

---

## Product Gates (pre-requisite for any paid external review)

Three in-house gaps must close before any human review contract is
signed. These are funded by you, not by the panel budget, and close
within a 1–4 week window depending on current product state.

| Gate | Gap | Why it gates | Exit criterion |
|------|-----|--------------|----------------|
| **G1 — Install works today** | [PRODUCT-017](./gaps.yaml) — stopwatch clean-machine install | Research credibility means nothing if `brew install chump` is broken. UX-001 is marked `done` but hasn't been re-verified. | Fresh run in last 14 days, < 60s, committed to docs/FTUE-VERIFICATION-YYYY-MM-DD.md |
| **G2 — You can show it** | [PRODUCT-016](./gaps.yaml) — 3-minute unedited demo video | If you can't record end-to-end, there's no product to review. | docs/DEMO_SCRIPT.md + unedited recording committed |
| **G3 — Users activate** | [PRODUCT-015](./gaps.yaml) — activation funnel telemetry | Research reviews key off a product worth validating. CPO sets numeric threshold (e.g. "10 non-Jeff humans activate/month"). | `chump funnel` shows CPO-set activation threshold met for ≥ 1 month |

**Until G1 + G2 + G3 pass, the only spend is the AI pre-audit (<$500)
and the product/UX/GTM seats. Research reviewers stay uncommissioned.**

---

## Review Scope

Chump is a multi-disciplinary research + systems + product project:

- **Research:** Active Inference consciousness framework, cognitive substrate validation, novel eval methodology
- **Systems:** Distributed multi-agent coordination (Mac + Pixel + future nodes), NATS + ambient.jsonl coordination, mobile integration
- **Product:** Local-first PWA, CLI UX, commercialization readiness
- **Engineering:** Rust codebase, cross-compilation (Android), CI/CD with coordination guards, reproducibility/open science standards

No single expert covers all angles. The panel below is comprehensive; tiered options follow.

---

## Comprehensive Panel (12 Experts, product-first order)

**Reduced from 14 → 12** by collapsing three research seats (Consciousness,
Eval Methodology, Research Integrity, Active Inference Theorist) into **one
combined Research Credibility seat** that only engages after Product Gates
G1–G3 pass. Other seats reorder with product/UX/GTM first.

### Tier 1: Product & Market (3 experts) — **engage first**

| Expert | Focus | Why | Deliverable |
|--------|-------|-----|-------------|
| **Product Strategist & GTM Lead** | North Star clarity, competitive positioning, commercialization strategy | Red Letter flagged zero product velocity two cycles running. Gates everything downstream — if the product lacks a wedge, research reviews don't help. | Strategic audit: North Star clarity (1–10), competitive gap analysis (feeds PRODUCT-018), GTM readiness, commercialization options (feeds PRODUCT-019), launch sequencing |
| **UX/Usability Researcher** | PWA install/onboarding flow, multi-turn agent mental models, accessibility | Product Gate G1/G2 tells you *if* install works; UX research tells you *why* users drop off when it does. Required reading of activation funnel. | UX audit: first-60s flow testing, task completion rates, mental model alignment, accessibility (WCAG 2.1), redesign priorities |
| **Mobile & Embedded Systems Engineer** | Android cross-compilation, Termux constraints, Pixel deployment, edge inference | Pixel story is a product differentiator. Can Pixel actually run the workloads? Is deployment realistic? | Hands-on Pixel testing; deployment checklist; Termux limitation doc; inference latency benchmarks |

### Tier 2: Engineering & Operations (3 experts) — **engage in parallel with Tier 1**

| Expert | Focus | Why | Deliverable |
|--------|-------|-----|-------------|
| **Code Quality & Maintainability Reviewer** | Rust idioms, crate structure, test coverage, sustainability | Mostly AI-covered (INFRA-044 dispatcher). Human for 1h sign-off on AI findings only. | Sign-off on AI findings + architectural refactor call (if needed) |
| **CI/CD & DevOps Specialist** | Merge queue discipline, PR atomicity, worktree hygiene, five pre-commit guards | The coordination pipeline is novel. Do guards actually prevent stomps or create false confidence? Mostly AI-testable via chaos harness. | Half-day review of AI chaos-harness results + hardening priorities |
| **Documentation Quality Auditor** | Doc infrastructure, knowledge management, onboarding | **Fully AI-substitutable via DOC-004** (onboarding simulation). Human only if sim fails. | Scoping for rewrite *only* if onboarding sim fails |

### Tier 3: Systems & Scale (2 experts) — **engage only if FLEET/Mabel is imminent**

| Expert | Focus | Why | Deliverable |
|--------|-------|-----|-------------|
| **Distributed Systems Architect** | FLEET 5-layer design, NATS coordination, lease management, fault tolerance | Validates multi-node architecture before Mabel onboarding. Skip entirely if Mabel onboarding is >3 months out. | Architecture audit: soundness 1–10, scaling limits, failure mode inventory, FLEET readiness score |
| **Inference Cost Optimization Engineer** | Provider cascade, cost-routing, Pixel inference feasibility | Gated on monetization hypothesis (PRODUCT-019). Skip if OSS-only direction picked. | Cost audit: cascade ROI, Pixel breakeven, provider routing |

### Tier 4: Safety & Integrity (2 experts) — **engage when product has users**

| Expert | Focus | Why | Deliverable |
|--------|-------|-----|-------------|
| **LLM Safety & Autonomy Expert** | Tool use gating, autonomy escalation, credential handling, multi-agent trust | When does Chump act unsupervised? Credential mgmt in multi-node? Gated on having users to protect (G3 passing). | Safety audit: threat model, autonomy gates review, credential isolation testing, remediation roadmap |
| **Business Licensing & Open-Source Governance** | OSS readiness, contributor guidelines, compliance | Fully AI-substitutable (INFRA-044 covers cargo-deny, license scan). 1h human only if commercial ship imminent. | Sign-off on AI-generated license audit + CONTRIBUTING.md |

### Tier 5: Research Credibility (1 seat, gated) — **engage only if Product Gates G1+G2+G3 all pass**

| Expert | Focus | Why | Deliverable |
|--------|-------|-----|-------------|
| **Combined Research Credibility Reviewer** | Consciousness/AGI framing + eval methodology + Active Inference theoretical grounding + preregistration discipline | Previously 4 separate seats (Consciousness, Eval Methodology, Research Integrity, Active Inference Theorist). Collapsed into one senior reviewer engaged only when there's a product worth validating research claims for. Red Letter #4 credibility debt is real — but it's debt against a product, not a standalone research claim. | Combined research audit (8–12 pages): claim-to-literature map, eval methodology rigor, preregistration compliance, theoretical novelty, recommended repositioning |

**Gating:** This seat remains **uncommissioned** until PRODUCT-015
activation funnel shows CPO-set threshold met. Until then, AI pre-audit
(RESEARCH-029 in earlier draft — now deferred) produces a claim ledger
the reviewer could work from *if* engaged. The $6K–8K saved here is
reallocated to Tier 1 product/UX work.

---

## AI vs Human Matrix

The matrix below enumerates all 14 original review dimensions (not the 12
consolidated seats) — it maps work to AI-automation potential at a finer
granularity than the panel itself. The four "Research Foundations" rows
map to the single **Combined Research Credibility Reviewer** seat in the
panel above, but their AI-automatable portions still run separately in
the AI pre-audit.

Each dimension is scored on **% automatable today** (Claude agents + OSS
tooling, no human in the loop) and **what the human is still needed for**.
Percentages are "how much of the deliverable, by effort, AI can produce
at equal-or-better quality than a paid expert." Residual % is where a
credentialed human adds signal a model cannot.

| # | Role | % AI | AI substitute / tooling | Human still needed for |
|---|------|-----:|-------------------------|------------------------|
| 1 | Consciousness/AGI Framework | 30% | Claude agent: extract every consciousness/AI claim in `docs/` + `crates/`, map each to published literature (arXiv/Semantic Scholar API), flag unsupported claims. Output: claim-by-claim ledger. | Credentialed philosopher/cogsci researcher to sign off on framing and novelty. No model can credibly do this. |
| 2 | Eval Methodology Auditor | 75% | Agent pass: recompute CIs, power analysis, judge-agreement κ, n-size checks from `docs/eval/` raw results; diff preregistered hypothesis vs reported outcome per EVAL-\* gap. Python stats scripts + Claude synthesis. | ML stats PhD to adjudicate contested methodology calls (e.g. is LLM-as-judge valid *for this task*). Narrow scope after AI pass. |
| 3 | Research Integrity & Reproducibility | 85% | Fully scriptable: scan `docs/eval/preregistered/` vs closed EVAL-\*/RESEARCH-\* gaps, check timestamp ordering, flag missing preregs, audit OSF/GitHub release wiring. New hook: `scripts/prereg-audit.sh`. | Spot-check of 3–5 flagged cases + sign-off on open-science wiring. |
| 4 | Distributed Systems Architect | 45% | Agent: enumerate every FLEET failure mode from code, generate chaos-test scenarios (node death, lease expiry races, NATS partition), drive `madsim`/`turmoil` simulation, produce failure-mode inventory. | Senior distributed engineer for architectural judgement (is the 5-layer split right, is NATS the right substrate). |
| 5 | Mobile & Embedded | 20% | Agent can parse `logcat`, analyze Termux failures, run cross-compile smoke tests in CI. Benchmark-log synthesis. | **Hands-on Pixel testing is not automatable.** Buy 2h of a mobile engineer's time; AI pre-processes their logs. |
| 6 | Performance & Benchmarking | 85% | Claude writes `criterion` suites + `ambient.jsonl` load generator, runs 10-node simulation locally, produces latency distributions. `cargo bench` + flamegraph + agent summary. | Senior perf engineer to set SLO priorities; rarely needed if numbers are clean. |
| 7 | Code Quality & Maintainability | 75% | Stack: `cargo clippy -- -W clippy::pedantic`, `cargo-llvm-cov`, `cargo-udeps`, `cargo-machete`, `cargo-audit`, plus a Claude reviewer agent (already live: `.claude/agents/code-reviewer-agent.sh`). Produces debt inventory + refactor queue. | Staff Rust engineer for architectural refactors; optional. |
| 8 | CI/CD & DevOps | 65% | Agent writes chaos tests for five pre-commit guards, simulates 50 concurrent `gap-claim.sh` races, validates merge-queue recovery paths, audits `bot-merge.sh` escape hatches. | Ops engineer to review hardening recommendations; half-day engagement. |
| 9 | Documentation Quality | 85% | Automatable end-to-end: link-rot (`lychee`), freshness (git-age vs touched-code), **onboarding simulation** (spawn fresh Claude agent with only `docs/` mounted, ask it to execute first-task, score completion). `docs/gardener` already exists. | None if AI sim passes; else a tech writer for rewrite scoping. |
| 10 | Product Strategy & GTM | 25% | Agent: competitive-landscape scrape (Cursor, Cline, Aider, Devin), feature-diff matrix, pricing comparison. North Star clarity audit from repo docs. | Human strategist — market intuition, founder network, positioning. Not automatable. |
| 11 | UX/Usability | 40% | Claude-in-Chrome agent can run first-60s flow, capture screenshots, measure task-completion latency, check WCAG via `axe-core`. Simulated new-user session. | Real users. Cheaper substitute: 5 users × 30min remote tests on UserTesting.com (~$300) + AI synthesis of recordings. Replaces a $5K UX engagement. |
| 12 | LLM Safety & Autonomy | 60% | Agent red-team: enumerate every tool-use surface, fuzz help-seeking protocol with adversarial peers, test credential isolation in multi-node. `garak`, `pyrit` for LLM probing. Threat-model draft. | AI-safety-trained human to sign off on autonomy gates and multi-agent trust model. Narrow scope after AI pass. |
| 13 | Business Licensing & OSS | 85% | Fully automatable: `cargo-deny`, `cargo-about`, `licensee`, `scancode-toolkit` for dep-license audit. Claude drafts CONTRIBUTING.md + governance model from similar OSS projects. | OSS lawyer for 1h sign-off if shipping commercially — not always needed. |
| 14 | Inference Cost / Active Inference | 80% / 20% | Cost: Claude computes cascade ROI from provider price sheets + measured token counts, simulates Pixel inference breakeven. **Active Inference theory: AI cannot credibly validate novelty** — needs credentialed theorist. | Active Inference: credentialed researcher (Friston-lineage). Cost: optional human. |

**Aggregate:** mean across roles ≈ **57% AI-automatable**. The remaining ~43%
concentrates in four roles (#1 consciousness, #5 mobile hands-on, #10 GTM,
#14b Active Inference theorist). Those four are where review dollars should
actually go.

---

## AI Pre-Audit Pipeline (new — runs before any human is engaged)

**Goal:** Land ~60% of the panel's findings from dispatched agents + OSS
tooling in ~1 week, at cost ≈ API spend ($100–500 total). Produces an
"AI Findings Report" that (a) closes cheap gaps directly (e.g. license
audit, link-rot) and (b) scopes the narrow slices where humans are
actually needed — so human contracts ship at half the hours.

| Stage | What runs | Output | Triggers human if… |
|-------|-----------|--------|---------------------|
| **A. Static & license sweep** | `cargo clippy --pedantic`, `cargo-deny`, `cargo-audit`, `cargo-udeps`, `cargo-machete`, `lychee`, `scancode-toolkit` | Code-debt inventory, CVE list, license conflicts, dead deps, doc-link rot | Critical CVE or copyleft conflict → OSS lawyer (1h) |
| **B. Stats re-audit** | `scripts/prereg-audit.sh` (new) + Python re-computes CIs/power/κ from every EVAL-\* raw result | Prereg-vs-result diff, power tables, κ matrix | Contested stats call → ML-stats PhD (narrow scope) |
| **C. Claim-to-literature map** | Claude agent extracts every consciousness/AI/JEPA/Active-Inference claim → Semantic Scholar / arXiv lookup | Claim ledger w/ citation support levels | Unsupported flagship claims → credentialed reviewer |
| **D. Chaos & race harness** | `madsim` / `turmoil` FLEET simulation, 50-way `gap-claim.sh` race test, NATS partition tests | Failure-mode inventory, guard-effectiveness report | Novel failure mode not in known taxonomy → distributed systems human |
| **E. Onboarding sim** | Fresh Claude agent mounted only on `docs/`, asked to execute a first task from scratch | Pass/fail + friction transcript | Fail → tech writer scoping |
| **F. Red-team sweep** | `garak` + Claude adversarial-peer fuzzer against help-seeking protocol + tool-use surfaces | Threat model v0, credential-isolation test results | Unpatched exploit class → AI-safety human |
| **G. Cost & competitive scrape** | Claude + provider APIs: cascade ROI, competitor feature matrix | Cost spreadsheet, positioning draft | Strategic questions unresolved → GTM human |
| **H. Hands-on mobile** | — (no AI substitute) | — | **Always** → mobile engineer, 2–4h |

**Implementation footprint:** ~8 new scripts under `scripts/audit/` + one
dispatcher (`scripts/audit/run-all.sh`) that orchestrates via the
existing `chump-orchestrator` multi-agent infrastructure. Estimated build
time: 2–3 days, mostly wrapping tools Chump already uses.

---

## Tiered Options (by Budget & Timeline)

### Tier 0 — Product Gates + AI Pre-Audit (In-house, ~1–4 weeks, <$500)

**Do this before anything else, every time.** No paid external reviewers until
this completes.

- **Product Gates G1+G2+G3** — [PRODUCT-015](./gaps.yaml), [PRODUCT-016](./gaps.yaml), [PRODUCT-017](./gaps.yaml). Your team. Effort: S + S + M.
- **AI Pre-Audit stages A + E + G** — [INFRA-044](./gaps.yaml), [DOC-004](./gaps.yaml), [PRODUCT-018](./gaps.yaml). Claude agents + OSS tooling. Effort: S each.
- **Deferred AI pre-audit stages** (B, C, D, F): only run if/when research/systems/safety seats are actually engaged. Premature otherwise.

**Output:** activation funnel live; install re-verified; demo recorded;
static/license/CVE findings triaged; onboarding sim scored; competitive
matrix written. You now know if the product is worth reviewing.

**Exit criterion:** G3 (activation funnel) shows CPO-set threshold met
for ≥ 1 month. If yes, proceed to Tier 1. If no, iterate on product
until it does — no external review spend.

---

### Tier 1 — Product & Market Review (post-gates, 3 weeks, $8K–12K)

**Commission only after Tier 0 gates clear.**

1. **Product Strategist & GTM Lead** — full engagement against PRODUCT-018 (competitive matrix) and PRODUCT-019 (monetization) as input docs. ~$5K.
2. **UX Researcher** — substitute with 5 users × UserTesting.com (~$300) + AI synthesis of recordings. Optional $2K human for deep redesign if UX-001 passes but activation is low.
3. **Mobile & Embedded Engineer** — 2–4h hands-on Pixel validation (~$1.5K; not AI-substitutable).

**Why this slice:** Validates the product's right to exist commercially
*before* paying to validate the science behind it. If this tier produces
a "no wedge" or "no activation curve" finding, all downstream tiers are
cancelled with no sunk cost.

---

### Tier 2 — Engineering & Ops Sign-off (parallel with Tier 1, 2 weeks, $2K–4K)

**All narrow-scope; AI pre-audit did the legwork.**

1. **Code Quality Reviewer** — **dropped**: [INFRA-044](./gaps.yaml) covers it.
2. **CI/CD Specialist** — half-day review of AI chaos-harness findings (~$2K). Only if FLEET is imminent.
3. **Documentation Quality Auditor** — **dropped**: [DOC-004](./gaps.yaml) covers it unless the sim fails.
4. **Business Licensing** — 1h human sign-off on AI license audit, only if commercial ship imminent (~$500).

---

### Tier 3 — Systems & Safety (only if product has scale or users, 3 weeks, $4K–8K)

**Commission only if scale is real or users exist.**

1. **Distributed Systems Architect** — half-day review of AI chaos-harness findings (~$2K). Skip if Mabel onboarding > 3 months out.
2. **Inference Cost Optimization Engineer** — half-day validation of PRODUCT-019 unit-economics (~$1.5K). Skip if OSS-only picked.
3. **LLM Safety Expert** — sign off on AI red-team findings from deferred Stage F (~$2.5K). Only if G3 passed (real users to protect).

---

### Tier 4 — Research Credibility (gated on product success, 3 weeks, $6K–8K)

**Commission only if:** Product Gates G1+G2+G3 pass, Tier 1 shows a real
wedge + activation curve, and there's an external reason (publication,
enterprise sale, funding round) to pay for research credibility.

1. **Combined Research Credibility Reviewer** — consciousness framing +
   eval methodology + Active Inference + preregistration in one senior
   engagement. Input docs: AI claim ledger (deferred RESEARCH-029 if
   commissioned), prereg audit (deferred EVAL-077), raw eval data.

**This tier does not exist in the default pipeline.** It's a
conditionally-funded extension, not a default deliverable.

---

### Cost summary

| Pipeline | When | Human Spend | AI Spend |
|----------|------|------------:|---------:|
| Tier 0 only | Always first | $0 | <$500 |
| Tier 0 + 1 | After product gates | $8K–12K | <$500 |
| Tier 0 + 1 + 2 | With eng sign-off | $10K–16K | <$500 |
| Tier 0 + 1 + 2 + 3 | With scale/safety | $14K–24K | <$1K |
| Full (+ Tier 4) | Only if externally justified | $20K–32K | <$1K |

**Old comprehensive estimate was $60K–80K.** New ceiling is ~$32K
post-AI-pre-audit, and Tier 4 is no longer part of the default path —
it's opt-in only when there's a specific external reason to pay for
research credibility.

**When to do this:** Before seeking external funding, enterprise partnerships, or open-sourcing. Validates every surface.

---

## Reviewer Sourcing & Logistics

### Where to Find Experts

| Role | Where | Examples |
|------|-------|----------|
| Consciousness/AGI | Universities (neurosci, philosophy, AI safety), research labs | UC Berkeley AI Safety, Future of Humanity Institute, OpenPhil network |
| Eval Methodology | ML research (academia + industry), statistics | NeurIPS Program Committee, ML conferences, arXiv authors in evals |
| Distributed Systems | Systems conferences (OSDI, NSDI), cloud infrastructure | Companies: Meta (CRDT), Apple (distributed), Open source: CNCF community |
| Mobile Engineering | Android maintainers, React Native, embedded Rust | Rust embedded WG, Android core contributors |
| Product Strategy | Early-stage AI tools (Series A/B), venture builders | Sequoia, a16z, or founder networks (Stripe, Anthropic alums) |
| Code Quality | Rust, open-source maintainers | Tokio, Serde, TiKV authors; Rust foundation |
| UX Researcher | User research firms (Maze, UserTesting), AI tool companies | Cursor, VS Code team, design agencies with tech focus |
| LLM Safety | AI safety organizations | MIRI, Anthropic (safety team), DeepMind interpretability |
| Open-Source Governance | Linux Foundation, Kubernetes SIGs, OSS legal | LF Open Compliance Program, Software Freedom Conservancy |

### Engagement Model

**Per expert (recommended):**
- **Kickoff call** (1h): brief on Chump, answer questions, set scope
- **Review period** (2–3 weeks): expert reads docs, runs tests, interviews team as needed
- **Written audit** (4–6 pages): findings, risk tiers (critical/high/medium/low), recommendations
- **Debrief call** (1h): walk through findings, discuss remediation
- **Follow-up** (optional): post-gap closure, re-audit specific recommendations

**Suggested contract:** Fixed-price ($2K–5K per expert, varies by seniority + depth) + travel if hands-on testing needed (mobile engineer, performance specialist).

---

## Audit Deliverables Template

Each reviewer should provide:

1. **Executive Summary** (1 page)
   - Overall readiness score (1–10)
   - Top 3 risks
   - Recommendation (ship/rework/research/defer)

2. **Detailed Findings** (4–6 pages)
   - Strength areas (what you're doing well)
   - Risk inventory (tiered: critical, high, medium, low)
   - Specific recommendations (actionable, scoped)

3. **Suggested Gaps** (if applicable)
   - New gap IDs (AUDIT-XXX) for identified work
   - Priority + effort estimates
   - Dependencies

4. **Confidence Statement**
   - "I reviewed X for Y days, tested Z, and am N% confident in this assessment"

---

## Timeline & Sequencing

### Phase 1: Sourcing (Week 1)
- Identify + outreach to 3–4 candidates per role
- Negotiate contracts
- Schedule kickoff calls

### Phase 2: Execution (Weeks 2–5)
- Kickoff calls (all experts)
- Parallel review work
- Team supports with access, Q&A, live demos as needed

### Phase 3: Synthesis (Week 6)
- Collect all written audits
- Debrief calls (1h each, grouped by role if possible)
- Aggregate findings into unified "Chump Readiness Report"

### Post-Review
- Triage findings into new gaps (AUDIT-XXX)
- Prioritize against existing roadmap
- Track closure (re-audit after remediation if critical)

---

## Risk Factors & Known Blindspots

**Known debt from Red Letter:**
- Research credibility (consciousness framework, eval rigor)
- Product velocity (zero shipped features last 2 cycles)
- Documentation staleness
- Dogfood reliability (REL-001/002 blockers)

**This review should validate or challenge each of these.**

---

## Success Criteria

**After Tier 0 (mandatory baseline):**

- ✅ Install → first-task → day-2-return funnel live and instrumented
- ✅ Clean-machine install re-verified in last 14 days
- ✅ 3-minute unedited demo recording exists
- ✅ Static/license/CVE findings triaged; critical fixes filed as gaps
- ✅ Onboarding sim passes (or files DOC-* gaps for what broke)
- ✅ Competitive matrix written with one-sentence wedge

**After Tier 1 (product gate passed):**

- ✅ Product North Star clarified + positioning validated by external strategist
- ✅ UX drop-off points identified from real-user testing
- ✅ Pixel deployment validated on hardware

**After Tier 2 (engineering sign-off):**

- ✅ AI chaos-harness findings reviewed by ops human
- ✅ License audit signed off (if shipping commercial)

**After Tier 3 (scale/safety, conditional):**

- ✅ FLEET architecture vetted for Mabel onboarding
- ✅ Cost model validated against real inference spend
- ✅ Safety + autonomy gates audited by credentialed human

**After Tier 4 (research credibility, opt-in):**

- ✅ Consciousness research claims validated or repositioned
- ✅ Eval methodology publication-ready or retest plan filed
- ✅ Active Inference novelty assessed

**Commercialization path** (identified at Tier 1, tested through
Tiers 2–3, validated at Tier 4 if externally required):
open-source, enterprise, research licensing.

---

## Next Steps

1. **CPO sets activation threshold.** What number on the PRODUCT-015 funnel (install/first-task/day-2-return) unlocks paid external review? Default: 10 non-Jeff humans complete a first task and return on day 2, sustained for 1 month.
2. **Ship Product Gates G1+G2+G3.** In-house, no spend. Order: PRODUCT-017 (re-verify install) → PRODUCT-016 (record demo) → PRODUCT-015 (funnel live).
3. **Run Tier 0 AI pre-audit in parallel.** INFRA-044 + DOC-004 + PRODUCT-018. Claude agents + OSS tooling, <$500 API spend total.
4. **Wait for activation signal.** If threshold met within 1–2 months → proceed to Tier 1. If not → iterate on product, no external review spend.
5. **Commission Tier 1 (Product & Market) first** after gates clear. ~$8K–12K. Scope the RFPs against PRODUCT-018/019 findings, not blank-check audits.
6. **Tier 2+3 in parallel or after Tier 1** based on engineering/scale/safety priorities.
7. **Tier 4 (Research Credibility) only if externally justified.** Publication, enterprise sale, or funding round — not as a default deliverable.

---

## Contacts & Notes

**Current reviewers already engaged:**
- Gemini (external architecture reviewer) — ongoing feedback

**Gaps in current review coverage:**
- No LLM safety expert on current roster (acceptable — Tier 3, only if G3 passes)
- No product/GTM specialist (Tier 1 priority — source first after gates clear)
- No UX research (Tier 1 priority — source first after gates clear)
- No mobile hardware validation (Tier 1 priority — source first after gates clear)

**Document history:**
- 2026-04-24: Initial panel design (14 experts, 3 tiers)
- 2026-04-24 (rev 1): AI-substitution pass — added AI-vs-Human matrix, AI Pre-Audit pipeline, revised costs down 60–70%
- 2026-04-24 (rev 2, CPO reframe): product gates G1+G2+G3 made mandatory pre-requisite for paid external review; panel reduced 14→12 seats by consolidating 4 research seats into 1 gated seat; tiers reordered product-first; research credibility tier made opt-in; ceiling $60K–80K → $32K post-AI-pre-audit
