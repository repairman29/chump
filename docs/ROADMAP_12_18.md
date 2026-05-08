# Chump — 12-18 Month Strategic Roadmap

**Time horizon**: 2026-05-08 → 2027-05 (Q1 2027). Reviewed quarterly by operator.
**Sibling doc**: [`ROADMAP.md`](./ROADMAP.md) (30-day operational plan).
**Foundation doc**: [`process/STATE_OF_UNION_2026-05-08.md`](./process/STATE_OF_UNION_2026-05-08.md).

---

## The inflection moment

Today's snapshot:
- **1300+ PRs shipped** in days
- **4-layer autonomy stack** with operator-agent (INFRA-737) about to land
- **Self-healing infra** covers ~70% of failure modes
- **Mission balance** enforced mechanically (INFRA-720 picker bias)
- **Cost transparency** lands within 24-48h (INFRA-729/730/731)

Operator's role is shifting from **musher** (driving the dogs) to **strategist** (setting direction). This roadmap is built around that shift: the next 18 months should make Chump *not need an operator at all* for routine work, while making the operator dramatically more leveraged for strategic work.

The bet: in 18 months, "every engineer has an AI fleet" is the dominant pattern. Chump's role is to be the most credible, observable, and economical fleet in that landscape.

---

## North Star

**Chump becomes the de facto self-hosted multi-agent system for serious software work — where "serious" means: with cost data, audit logs, mission balance, and ship-rate measured against verifiable benchmarks.**

If we get this right:
- Solo developers / small teams ship at 5-10× their unaided pace
- Robotics + embedded teams have a proprietary-data-safe AI engineering layer
- Research groups have a reproducible publication pipeline
- Open-source maintainers have an unpaid junior engineer who never sleeps

If we don't get this right, the market goes to whoever ships **plausible** autonomy without the credibility infrastructure. We've decided that lane is a race we'd lose; the credible lane is the one we win.

---

## Quarterly thrusts

### Q3 2026 (now → August): "Honest scale"

**Goal**: prove the system runs unattended for ≥7 days at a measurably-cheaper $/feature than today, on at least one external repo.

| Thrust | Concrete outcome | Why |
|---|---|---|
| **Land cost measurement end-to-end** | INFRA-729/730/731 in main; per-PR cost data flowing for ≥1 week; pricing-drift alerts firing weekly | Without this, we can't make defensible cost claims. Everything else depends on it. |
| **Operator-agent in production** | INFRA-737 shipped; Sonnet runs the routine triage; Opus only invoked on filed escalations | Frees operator from daily babysitting. The "won't need to mush soon" moment. |
| **Free-tier becomes real** | INFRA-733 tool-call adapter ships; Groq Llama 3.3 70B can ship `xs` mechanical work; first $0-shipped PR | Step-change in unit economics. Today's Cerebras/Groq pilot is half-built. |
| **First external design partner** | One non-Chump repo (chump-proprietary or grant partner) running for ≥30 days | The product story stops being "Jeff's repo" |
| **Compliance-grade audit log** | `ambient.jsonl` retention policy; SOC 2-friendly event schema; encrypted state.db option | Robotics + grant partners need this; nothing else proves the credibility moat |

### Q4 2026 (Sep → Nov): "Benchmark-honest"

**Goal**: publish verifiable performance numbers against industry benchmarks. Stop being "Jeff's interesting project" and become "the system with the credibility data."

| Thrust | Concrete outcome | Why |
|---|---|---|
| **SWE-bench / Aider benchmark scores** | Public scores on standard datasets; ≥1 academic-quality writeup | "It ships" needs to be quantified against shared benchmarks the industry trusts |
| **Multi-machine fleet** | NATS-coordinated workers across ≥2 hosts; live failover; demonstrated for 7-day soak | Today's fleet is one-machine. Real customers need redundancy. |
| **Fleet of 20-50 workers** | Resource governor that scales worker count by available headroom; LLM provider rate-limit awareness | Per-machine fleet maxes at ~8 workers today. Need an order of magnitude. |
| **Cross-judge eval pipeline** | At least 2 judge models (Anthropic + OpenAI or open-source) score each shipped PR; agreement metric tracked | Single-judge evals are dismissed by reviewers. Multi-judge is publishable. |
| **30-minute onboarding** | New repo setup time drops from 1-3 engineer-days to 30 minutes via `chump init` | The product becomes shareable, not just installable |

### Q1 2027 (Dec → Feb): "Specialized fleets"

**Goal**: domain-specific deployments. The fleet isn't generic; it knows it's working on Rust vs. Python vs. embedded. Quality up-shifts.

| Thrust | Concrete outcome | Why |
|---|---|---|
| **Domain-specialized prompts** | Rust fleet, Python fleet, Go fleet — each with language-specific tools, idioms, lints | Generic prompts hit a quality ceiling around `m`+ effort. Specialization breaks through. |
| **Embedded / robotics deployment** | Cross-compilation aware; works against `no_std` Rust, MicroPython, etc. | Reeve-class partners need this; opens a vertical |
| **Self-improving prompts** | Fleet evaluates its own ship-rate per prompt template; A/B picks the winner; promotes after N samples | Static prompts are leaving capability on the floor |
| **API for non-coding work** | "Chump-as-a-platform": gap-as-a-service, where the fleet handles docs, content, eval design — not just code | Expands TAM beyond software-only |
| **Multi-tenant pilot** | One fleet serving multiple repos with privacy walls between them | Small teams sharing infrastructure becomes economical |

### Q2 2027 (Mar → May): "The product"

**Goal**: ship something an outside operator can pay for or grant-fund without engineering help.

| Thrust | Concrete outcome | Why |
|---|---|---|
| **Managed cloud option** | One-click deploy on AWS/GCP/Hetzner with our reference fleet | Distribution beyond "weekend setup" |
| **Certified support tier** | Paid SLA; 4h response; included in commercial license | Revenue path that doesn't require a sales team |
| **Open-source the core, monetize operator UX** | Apache-2 core; commercial layer for fleet management dashboard, audit search, cost analytics | The classic open-core model, but the value is real |
| **Compliance audit ready** | SOC 2 Type 1 in progress; HIPAA path documented; FedRAMP-class requirements documented | Unlocks regulated-industry buyers |
| **Public case studies** | ≥3 named partners with measurable velocity/cost outcomes | Marketing finally has substance |

---

## Cross-cutting themes (every quarter)

### Credibility infrastructure (the moat)

Every cycle, we add a new credibility primitive:
- Q3: per-feature cost (INFRA-729) ✓ landing
- Q4: cross-judge eval (each PR scored by 2 models, agreement tracked)
- Q1: ship-quality grade per worker (FLEET-044 family)
- Q2: external audit (third party reviews our audit log methodology)

**Why this matters**: the AI agent space is *infested* with hype. Every demo is "look at this multi-agent system!" with no numbers behind it. Chump's only durable advantage is being the system whose claims are *boring to prove* — not because we're not capable, but because we're verifiable.

### Cost-curve riding

LLM costs drop ~30% / quarter. Free-tier capabilities double / 6 months. We don't fight this; we surf it:
- Cascade re-prioritization is automatic (bandit converges on cheapest viable slot)
- Rate-card freshness (INFRA-731) ensures we always ship at current best-price
- Free-tier-first dispatch becomes the default once INFRA-733 is solid
- Local-LLM (Ollama, vLLM, LM Studio on M-series) becomes viable for `xs`/`s` work as M4/M5 hardware arrives

**Bet**: by Q1 2027, ~50% of mechanical fleet work runs on free-tier or local LLMs. Sonnet/Opus reserve for `m`+ cognitive work. **Effective $0/day for most users.**

### Operator-as-strategist transition

This isn't a feature — it's a posture shift in how the system is used:
- Q3: operator-agent (INFRA-737) handles routine triage
- Q4: roadmap auto-generation (a new subagent class that proposes the *next quarter's* gaps based on observed bottlenecks)
- Q1: cost-aware planning (operator says "spend ≤ $X this month"; system plans around the budget)
- Q2: outcome-aligned planning (operator sets pillar weights; system files gaps that maximize toward the weights)

The operator's job 18 months out: **set 4-pillar priorities + budget + privacy policy quarterly**. The system handles everything else.

---

## What we lean into (accelerate)

1. **The "honest moat"**. Every chance to publish verifiable numbers, take it. Be the system that gets cited in academic papers.
2. **Self-hosted, no managed dependency**. As LLM regulators tighten, "your data never leaves your machine" becomes valuable beyond technical merits.
3. **Free-tier surfing**. As open-weight models hit production quality, our cascade architecture wins by default.
4. **Robotics / embedded specialization**. The Reeve-class partner is a wedge into a vertical that mainstream agentic AI ignores. Lean in.
5. **The "every engineer with their own fleet" framing**. Avoids the AI-replaces-engineers conversation entirely; positions us as engineer-augmenting infrastructure.
6. **Open-source community building**. The git history *is* the proof of life. Make the system's transparency a recruiting pitch.

## What we adapt to (defensive plays)

1. **Vendor consolidation**. Anthropic/OpenAI will ship "fleet mode." Our answer: be the most provider-agnostic substrate. The cascade is already there; double down.
2. **Cursor/Continue pivot to agentic**. They have distribution. Our answer: be the back-end infrastructure they could integrate with, OR own the "self-hosted" vertical they can't reach.
3. **Open-source agent frameworks scaling**. AutoGen, CrewAI, LangChain agents. Our answer: be the *honest* one — they're frameworks, we're a *system that ships*.
4. **AI regulation in regulated industries**. Our audit log is already built; lean into it as compliance-first product.
5. **Quality cliff at scale**. As fleets grow, we need the cross-judge eval (Q4) to land before we promise enterprise scale.
6. **Brand**: "Chump" plays anti-hype but may not pitch well. **Decision deferred to Q4 2026** — by then we have data on whether to rename or commit.

## What we monitor (signals to watch)

| Signal | Action if positive | Action if negative |
|---|---|---|
| Free-tier 70B models match Sonnet on SWE-bench | Default fleet to free-tier; Sonnet becomes premium tier | Stick with paid Sonnet; revisit local-LLM in 6mo |
| First competitor ships honest cost-tracking | Publish ours louder; differentiate on audit-log depth | Ours is still the first; don't change strategy |
| Anthropic ships "Claude Fleet" managed product | Position as "you can run your own fleet, here's why that matters" | Quietly de-prioritize the credibility moat (vendor solved it) |
| Robotics partner publishes case study | Expand vertical; hire 1 specialized engineer | Find a different vertical (medical? legal?) |
| Local-LLM on M4 Mac matches cloud quality | Pivot toward "your laptop has an AI engineering team" | Stay cloud-default |
| AI Act / executive order requires human review | Brand as "audit-trail-ready"; sell into regulated industries | Limit promises; clarify what autonomy we can credibly deliver |

---

## What this roadmap explicitly does NOT promise

1. **AGI-class general capability**. Chump ships software. It doesn't replace strategy, design, or human judgment on cross-cutting decisions.
2. **A web UI built by us**. The PWA is an experiment; if user demand goes elsewhere (TUI, IDE plugins, Discord bot), we follow. We're not married to PWA.
3. **A specific business model**. Open-core, managed cloud, certified support — these are options. We won't commit to one until we have ≥3 design partners with revealed willingness-to-pay.
4. **A team larger than 1-2 engineers + Opus**. The product is small-team-scaleable by design. Hiring beyond that is a Q2 2027+ question.

---

## Cadence

- **Quarterly review** (operator + Opus): rewrite the next quarter's thrusts based on what landed and what didn't. Run with the State of the Union doc as input.
- **Monthly audit** (operator-agent if shipped, otherwise Opus): pillar-mix + ship-rate + cost-trend snapshot. File gaps to fill any 2σ deviation from plan.
- **Weekly health** (automated, fleet-brief at SessionStart): operator scans for stalls + pillar imbalance + auth-storm + cost-cap warnings.

The roadmap is a living document. The first revision after Q3 2026 will probably look different than written here — that's correct. The point isn't to predict the future; it's to commit to a strategic posture and re-check it on cadence.

---

*Authored 2026-05-08 by Opus, end of high-throughput cycle. Verified against the State of the Union doc + the gap registry. Signed off by operator before merge.*
