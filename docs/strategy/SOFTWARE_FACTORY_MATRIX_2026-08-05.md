---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-08
---

# The Software-Factory Matrix — Chump audited against the 8-layer factory model

> **What this is.** The operator's 2026-08-05 essay frames the goal as an
> *organization made out of software*: not "what can AI do?" but "what jobs exist
> inside a software company, and how do we automate each one?" — 8 layers
> (executive → architecture → design → engineering → quality → operations →
> growth → continuous improvement) plus an orchestrator and one core primitive
> (Observe → Reason → Act → Report). This doc measures Chump/ChumpOS against
> that model, layer by layer, with a receipt per claim. Filed as **DOC-079**
> (outcome: CHUMPOS).
>
> **Provenance.** Sources: [`docs/CODEBASE_REALITY_MAP.md`](../CODEBASE_REALITY_MAP.md)
> (DOC-068), [`docs/MISSION.md`](../MISSION.md) (MISSION-014),
> [`docs/ROADMAP.md`](../ROADMAP.md) (ChumpOS arc), and a **live
> `scripts/dev/mission-scoreboard.sh` run on 2026-08-05T23:18Z**. Refresh when
> the scoreboard verdict or the ChumpOS phase position changes materially.

## 0. Honesty legend (REALITY_MAP §0 applies)

Chump systematically describes itself as more finished than it is — counters
have lied by large factors (CREDIBLE-146/149), and the fleet once ran dark for
26 days behind green dashboards. Statuses below therefore follow the
claimed-vs-verified discipline:

- ✅ **online** — outcome-verified against ground truth
- 🟡 **built** — code + doctrine exist; verification partial ("evidence of intent")
- 🟠 **thin** — fragments exist, no coherent capability
- ❌ **missing** — nobody sits in this chair except the operator

**The live receipt (2026-08-05):** scoreboard ① zero-human-touch PR merged in
BEAST-MODE this week = **YES** (4 of 10 merges agent-authored, zero-touch);
③ auto-deploy in place (MISSION-012 done); 18 merges/24h; verdict 🟢
HANDS-OFF territory. Mission-ship ratio ② = 5/18, still below the ⅔ scaling
gate.

## 1. Matrix — factory layers vs Chump today

| Factory layer | What Chump has | Status | Receipt |
|---|---|---|---|
| **L0 The factory** ("turn problems into working software") | The mission verbatim: zero human-written code, zero human merges; ChumpOS done-state: "anyone points it at a real problem, walks away, gets a finished, honest tool" | ✅ at N=1 | `docs/MISSION.md`; scoreboard ① YES 2026-08-05 |
| **Orchestrator** (breaks goals into jobs, never writes code) | Conductor doctrine ("feeds the fleet, does not become a worker"), picker, `gap decompose`, NATS push routing, A2A consensus + deliberator | ✅ | `crates/chump-orchestrator`, `chump-coord`; CLAUDE.md dispatch doctrine |
| **Core primitive** (Observe→Reason→Act→Report) | Worker loop + `ambient.jsonl` with CI-enforced `EVENT_REGISTRY.yaml`; `reality-check.sh` = observe-before-believe | ✅ | 85 PRs/24h (2026-06-05 KAIZEN); 18 merges/24h now |
| **L1 Executive** (PM / BA / planner) | Gap registry (state.db + YAML), outcomes table with intake firewall (MISSION-045: P0/P1 require `--outcome`), AC-required-to-pick, `gap audit-priorities` (META-046), hourly planner, `chump bootstrap "<sentence>"` (INFRA-2265) | 🟡 internal / ❌ customer intake | No requirements discovery from a business conversation — the BA chair is the operator's. Gap: **EFFECTIVE-357** |
| **L2 Architecture** | Bootstrap arch-decision step, `docs/rfcs/`, two-phase decomposition; tool-governance + WASM sandbox (~6K LOC) is real security architecture *for the fleet itself* | 🟠 | `crates/chump-policy`, `context_firewall.rs`, `sandbox*.rs`; no standing architect role; DB/UX architecture absent |
| **L3 Design** (UI / brand / interaction) | A CSS token lint gate — a gate, not a designer | ❌ | INFRA-1590. Gap: **EFFECTIVE-358** |
| **L4 Engineering** | Fleet workers (farmer-revived, pty-isolated), model-tier specialization (Opus orchestrates / Sonnet implements / Haiku sweeps), swappable harness under contract (OpenCode bulk + Claude hard-ship fallback), atomic claims/leases/worktrees, external-repo loop (onboard→improve→verify-merge), 9-provider cascade + cost governor | ✅ | `HARNESS_CONTRACT.md`; `onboard.rs`/`improve.rs`; scoreboard liveness |
| **L5 Quality** | `chump preflight` local CI mirror (<60s, INFRA-1673), ~89 CI test siblings, PR-review intelligence (~5K LOC), reviewer routing, adversarial + A/B eval harness that has honestly killed features, ChumpBench judge hardened (do-nothing PR scores STUB) | 🟡 lopsided | CREDIBLE-192/194/195; `adversary_llm.rs`. Deep on ship-safety; ❌ on product perf, accessibility, compatibility |
| **L6 Operations** | Self-deploy (MISSION-012 ✅), SLOs + `health --slo-check`, red-trunk self-fixer, farmer auto-revive, sleep/wake recovery, waste taxonomy + cost ceiling | ✅ for itself / 🟠 for shipped products | Scoreboard ③; `FLEET_SLOS.md`; caveat: gauges have lied — the Revival & Truth cycle exists to fix exactly this (CREDIBLE-151) |
| **L7 Growth** (docs, release notes, telling people, feedback) | Docs-site/book/pitch exist as artifacts; holler→Chump bridge is real *inbound* feedback plumbing; weekly digest open (PRODUCT-137); release notes / telling people / adoption — all human | ❌ mostly | Mirrors the operator's own bottleneck: built ≠ shipped ≠ **told** (GIVEAWAY_SOP Phase E). Gap: **EFFECTIVE-356** |
| **L8 Continuous improvement** ("what should improve today?") | Hourly planner (INFRA-1257), curator (META-065), kaizen retros, `gap rate` → picker bias, KPI impact reports, GEPA reflection + memory graph, capability-drift scan | ✅ | So strong it had to be governed: runaway self-improvement caused the gap-bankruptcy (1,214→25) and "signals are not work" (MISSION-045) |

## 2. Matrix — the essay's six phases vs where Chump is

| Essay phase | Chump reality | Status |
|---|---|---|
| 1. One excellent worker | Verified 2026-08-05: zero-touch PRs merged in BEAST-MODE | ✅ |
| 2. Team of specialists with contracts | Exists in a different grain — specialized by pipeline stage + model tier + curator lane, not job title; contracts real (`HARNESS_CONTRACT.md`, `AGENT_API.md`, A2A, `chump-handoff`) | 🟡 |
| 3. Factory OS (memory, queues, retries, audit, permissions) | Built deepest of all: state.db + gap store, leases, memory/reflection DBs + graph recall, durable execution, bypass-trailer audit, tool policy | ✅ |
| 4. Self-improving factory | Built, running, already had its first runaway accident (MISSION-045) | ✅ |
| 5. Multi-project organization | Phase A (1–10 repos) today; MISSION-032 = Phase B (10–100); per-repo namespace + privacy tiers decided | 🟠 |
| 6. Autonomous software company | Missing L1/L3/L7. But "explain every decision it made" is the *strongest* part: the gap-YAML + doctrine corpus is the least-replicable asset (REALITY_MAP §3) | ❌ overall |

**The shape of the delta:** the essay orders the phases front-to-back; Chump was
built **middle-out** — the OS (P3) and the improvement loop (P4) came first and
deepest, the single excellent worker (P1) was only *verified* in August 2026,
and the company-shaped ends (intake, design, growth) are the open chairs. Two
correspondences worth recording: (a) the essay's "biggest mistake = super
agent" thesis is independently ratified doctrine here — "opus in a trench
coat", feed-the-fleet-first, with measured evidence; (b) the essay's "the
factory manufactures decisions; software is the residue" is literally this
repo's most verified asset per its own audit — the doctrine + decision-log
corpus.

Grain note: Chump specialized by *stage* (plan→implement→review→ship→heal),
not by *job title*. Evidence so far says stage-specialization wins on the
factory floor, where the artifact is a diff; job-title specialization matters
at the boundaries (intake, design, growth), where the artifact is a decision.
That is exactly where the matrix goes red.

## 3. The path to "factory online"

The near-term sequence is already the ChumpOS arc (ROADMAP.md, position:
honest V1 → V1.5): make ① repeatable (MISSION-066); point the eval harness at
the fleet's own gauges (REALITY_MAP keystone 2); pass the ⅔ mission-ship gate
before scaling (② = 5/18 today); decompose the monolith (INFRA-3287).

What the factory model adds that the roadmap underweights — the three missing
chairs, filed 2026-08-05, in fill-order:

1. **EFFECTIVE-356** (P2, outcome CHUMPOS) — L7 growth worker: release notes +
   docs refresh from merged PRs; PRODUCT-137 is its first consumer. Smallest
   lift, feeds on data the fleet already has, attacks the operator's known
   bottleneck (telling people).
2. **EFFECTIVE-357** (P2, outcome COTG) — L1 objective intake: business
   objective → user stories + AC + outcome row + umbrella gap, through the
   MISSION-045 firewall. The difference between a fleet and a company; the
   COTG story verbatim.
3. **EFFECTIVE-358** (P3, outcome COTG) — L3 design pass for shipped
   user-facing tools. Deliberately last: only matters once external products
   flow through the front door.

_Filed 2026-08-05 under DOC-079. Companion gaps: EFFECTIVE-356/357/358._
