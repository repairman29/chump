# Market Positioning — Where Chump Takes The Lead

**Authored:** 2026-05-27 by curator-opus-overnight (Principal Strategist hat).
**Closes:** [INFRA-2081](../gaps/INFRA-2081.yaml).
**Inputs:**
- 2026-05-27 agent-framework intelligence brief (in-chat, operator-requested)
- [`docs/ROADMAP.md`](../ROADMAP.md) (Mission Yield, Wave order, 50/hr, Marcus arc)
- [`docs/strategy/ARCHITECTURAL_CRITIQUE_2026-05-25.md`](ARCHITECTURAL_CRITIQUE_2026-05-25.md) (21-finding self-audit; PR #2572)
- [`docs/strategy/SHIP_ORDER_VISION_2026-05-25.md`](SHIP_ORDER_VISION_2026-05-25.md) (wedge-class ship topology)
- [`docs/strategy/THE_FLOOR.md`](THE_FLOOR.md) + [`FLOOR_RETROSPECTIVE.md`](FLOOR_RETROSPECTIVE.md) (substrate ratchet)

**Output:** strategic compass for the next 4-12 weeks. NOT a roadmap (that's already filed). This sets up the **bounce-off-roadmap step** the operator named: take this map → cross-reference against `docs/ROADMAP_WAVES.md` + open gaps → identify where we already lead, where we have substrate but no narrative, where we need new work.

## The thesis (10,000 ft)

The agent-framework market is mid-bifurcation between cloud-API-orchestrators (LangGraph, AutoGen, CrewAI) and local-first runtimes (mlx-lm, Ollama, EXO). **Nobody has shipped the multi-agent coordination layer for the local-first half.** That's the white space.

Chump's substrate is already 60% of that coordination layer:
- Rust + sqlite state primitives (`atomic_claim`, `chump-coord`, `chump-agent-lease`)
- Persistent ambient event stream (`ambient.jsonl` + the indexed-store work in flight)
- Per-gap bounded execution (claim → /tmp worktree → bot-merge → auto-merge ARMED)
- Parent-enforced wall-clock kill on subagents (INFRA-1972 shipped 2026-05-25)
- Cost-aware backpressure primitives (`chump_gh` rate-limit, graphql-exhausted ambient)

The missing 40% is the *mission-completion* layer: actual local-LLM inference (C1 in the architectural critique), cross-machine state (C4), capability-aware routing.

**The lead-taking move:** stop framing Chump as "fleet runner for one operator" and reframe as "the multi-agent coordination layer for local-first." The substrate is already there. The narrative + the last-mile local-LLM wiring is what converts substrate into market position.

This document maps the 5 strategic white-spaces from today's intelligence brief into specific Chump capabilities, then proposes 5 strategic bets sequenced by the existing Wave order.

---

## The 5 Strategic Opportunities (mapped to Chump)

For each: *current position* (what's shipped), *gap* (what's missing for market lead), *pivot move* (the specific work that converts position to advantage), *dependencies*, *rough sizing*.

### Opportunity 1 — Durable Cross-Process State for Long-Running Agents

**Market gap:** every Python orchestrator stores agent state in a process-local dict. LangGraph's checkpointer is closest but SQLite-via-Python + GIL-bound + single-machine. Nothing in the market handles *"agent has been thinking 6 hours, machine restarted, resume cleanly."*

**Chump's current position (substantial):**
- `state.db` via r2d2 SQLite pool (`src/state_db.rs`) — persists across process death
- `atomic_claim` CAS gates (just shipped INFRA-1970 H1 lease-key-by-gap-ID 2026-05-25)
- `subagent_heartbeat` ambient event (existing) + `subagent_killed_at_budget` (shipped today)
- Per-gap worktree isolation (`/tmp/chump-<gap-id>/`)

**Gap:** single-machine only. State.db doesn't replicate. Lease CAS lives in one SQLite file. Architectural critique C4 documented this.

**Pivot move:** lift state.db to a coordination tier that survives single-machine death. Three options ranked by cost:
1. Postgres backend behind the same `chump-gap-store` crate interface (1-2 weeks)
2. NATS-KV CAS for `atomic_claim` with SQLite as local cache (3-4 weeks)
3. Full Raft/etcd for state.db (multi-month, probably wrong scope)

Recommend (1) as the next-quarter move; (2) as the multi-month follow-on once NATS is actually deployed cross-machine.

**Dependencies:** chump-coord NATS work (existing), `CHUMP_NATS_URL` unset in production today (per CLAUDE.md).

**Rough sizing:** 2-4 weeks for the smallest credible slice (Postgres path).

---

### Opportunity 2 — Cost-as-Control-Plane

**Market gap:** every framework treats cost as *observability* — log spend, alert if high. None treat cost as *primary scheduling input*. Enterprises won't deploy autonomous agents without budget enforcement they can prove bounded.

**Chump's current position (real):**
- **INFRA-1972 shipped today (2026-05-25)** — `wait_with_hang_detection` enforces `CHUMP_SUBAGENT_BUDGET_S` (default 900s) with SIGTERM + 30s grace + SIGKILL. Parent-enforced, not self-discipline. First-of-its-kind I'm aware of in the orchestrator space.
- `chump_gh` rate-limit self-throttle (`CHUMP_GH_MAX_CALLS_PER_MIN`, default 60) with `graphql_exhausted` ambient signal
- INFRA-1939 silent-wedge eliminator (under graphql exhaustion)
- per-PR ship pipeline with auto-merge ARMED + budget-bounded subagent dispatch

**Gap:** budget is wall-clock + API-call-count today. Not *token-cost* or *dollar-cost*. The schema is there; the enforcement isn't.

**Pivot move:** extend INFRA-1972's `subagent_killed_at_budget` to also track tokens consumed (via streaming counter from `claude -p`) and dollars spent. Add `CHUMP_SUBAGENT_TOKEN_BUDGET` + `CHUMP_SUBAGENT_DOLLAR_BUDGET` env vars. Emit `kind=subagent_killed_at_token_budget` / `kind=subagent_killed_at_dollar_budget` distinct from the wall-clock variant.

**Dependencies:** API-cost tracking already exists in `scripts/dev/api-cost-leaderboard.sh` — the data plumbing is there.

**Rough sizing:** 1-2 weeks. INFRA-1972 is the template; this is the same shape with different counters.

**Operator-facing narrative win:** *"Chump is the only multi-agent orchestrator with parent-enforced wall-clock + token + dollar budget kill primitives. Set your cap, walk away."*

---

### Opportunity 3 — Hardware-Aware Multi-Machine Routing for Local Meshes

**Market gap:** EXO is research-grade. Nothing production-quality routes "this query needs 70B context — Mac Studio 192GB / this is a small classification — Pi cluster qwen-1.5B." Local-mesh is the whole premise of edge-first agents but the routing layer doesn't exist.

**Chump's current position (substantial substrate, no productized surface):**
- `chump-coord` crate with NATS-KV primitives (FLEET-006, FLEET-034 push routing)
- Worker capability tagging (`WORKER_SKILLS`, `WORKER_MACHINE`, `WORKER_BACKEND` per CLAUDE.md §Push routing)
- Subject hierarchy `chump.work.<priority>.<class>.<machine>` (designed, partially wired)
- Self-hosted runner pool concept (4-runner M4 today)

**Gap:** the whole thing is opt-in + offline-fallback. In production today, `CHUMP_NATS_URL` is unset; everything's pull-mode against one SQLite file (architectural critique C4). The capability-aware routing decisions are unwritten.

**Pivot move:** stand up NATS production. Deploy chump-coord push-mode on the M4 + at least one secondary node (Pi or Mac mini or even iPhone-as-NPU-node per operator's earlier mention). Make the routing decision: model-X-loaded-on-machine-Y-with-Z-headroom + per-task per-capability dispatch.

**Dependencies:** physical second-machine deployment (operator action). Or: Pixel 8 Pro + iPhone 15 Pro Max as nodes (Termux + iSH respectively per operator's brainstorm) — interesting but thermal/battery constraints.

**Rough sizing:** 4-8 weeks for credible 2-node mesh demo. Multi-month for production.

**Strategic note:** this is the SECOND-quarter move, not the next-quarter move. The local-LLM wiring (Opportunity 4) is the prerequisite — no point routing to a Pi that can't run a model.

---

### Opportunity 4 — Provable Bounded SWE Autonomy

**Market gap:** Devin (closed, expensive, oversold) at one end; Aider (interactive, honest) at the other. Nothing in between offers *fully autonomous AND provably bounded* (cost/time/blast-radius declared up front). Trust gap blocks production adoption.

**Chump's current position (this is the strongest match):**
- Per-gap claim → /tmp worktree → bot-merge → auto-merge ARMED pattern (the entire fleet runs on this)
- Subagent dispatch with bounded wall-clock kill (INFRA-1972, today)
- Pre-push hook guards (Guard 0a INFRA-1671 preflight, Guard 3 INFRA-345 force-lease race, Guard 0e INFRA-1391 stack-on-main DIRTY preview)
- Auto-rebase daemon with operator-race lock (INFRA-1974, today)
- Force-push intent signal (INFRA-1971, today) — prevents auto-rearm from closing legitimately-force-pushed PRs

**Gap:** today this primitive is *used* — but it's not *productized as a SWE-autonomy product*. We treat it as fleet-management plumbing. It IS a category-creating feature.

**Pivot move:** wrap the existing pattern as `chump swe <prompt>` — a one-shot SWE-agent invocation with declared budget, sandboxed file scope (the `--paths` lease), pre-execution diff preview, post-execution rollback. The plumbing is shipped. The UX wrapper is 1-2 weeks.

**Dependencies:** INFRA-1972 (shipped), INFRA-1971 (shipped), INFRA-1970 (shipped). All landed today. The primitives line up exactly.

**Rough sizing:** 1-3 weeks for the wrapper + demo + docs.

**Operator-facing narrative win:** *"Chump SWE is the only autonomous coding agent that ships with provable per-task bounds. Set cost cap. Set scope. Set deadline. It SIGTERMs at budget. It rolls back on failure."* That's a differentiated story Devin can't match because Devin doesn't expose those bounds.

---

### Opportunity 5 — Honest Observability for Multi-Agent Systems

**Market gap:** LangSmith, AgentOps, etc. measure single-agent traces. None handle multi-agent coordination signals — `claim_blocked`, `subagent_killed_at_budget`, `lease_expired`, `force_push_race_deferred`. Cross-agent observability is empty.

**Chump's current position (the deepest moat):**
- `ambient.jsonl` event stream (every coordination decision emits)
- 500+ registered event kinds in `docs/observability/EVENT_REGISTRY.yaml`
- Strict-mode coverage gate (catches emit-without-register and register-without-emit drift — caused trunk-RED this afternoon when THE FLOOR flipped strict, now stable)
- Scanner-anchor convention (`# scanner-anchor: "kind":"..."`)
- Per-kind effect_metric, emitter, trigger, consumers fields

**Gap:** all of this is internal-only. There's no operator-facing surface that says "look at the 5 coordination decisions Chump made on your task in the last hour, with cost and outcome." There's no exported schema other agents could adopt.

**Pivot move (two phases):**
1. **Index the ambient stream** (architectural critique H4 / INFRA-1973) — SQLite-indexed store with `(ts, kind, session_id)` btree so consumers can query in < 100ms even at 10K events/day.
2. **Publish the schema** as `chump-agent-events-v1` — a public spec the rest of the multi-agent ecosystem can adopt. OpenTelemetry-for-multi-agent. First-mover advantage in defining the standard.

**Dependencies:** INFRA-1973 already filed (architectural critique sub-gap, in queue).

**Rough sizing:** index work is 2-3 weeks; published-spec is a 1-week doc effort once the index is stable.

**Strategic note:** this is the *moat* play. The orchestration layer that defines the observability schema for multi-agent becomes the gravity well the others have to integrate with. LangChain did this for single-agent traces with LangSmith. Nobody owns multi-agent.

---

## The 5 Bets — Sequenced by Wave Order

The existing `ROADMAP_WAVES.md` defines 4 waves; I'm slotting these bets into that discipline.

### Wave 1 (this week, ships before any other bet starts)

**Bet 1 — SWE-Autonomy Wrapper (Opportunity 4).**
The `chump swe <prompt>` wrapper that exposes the bounded-execution primitives as a one-shot SWE-agent. All primitives shipped today. UX + docs + demo = 1-3 weeks. **Smallest move that creates the loudest narrative win** because the primitives are real and the competitor (Devin) can't match the bounded-execution story.

### Wave 2 (next 2-4 weeks)

**Bet 2 — Cost-as-Control-Plane completion (Opportunity 2).**
Extend INFRA-1972 to token + dollar budgets. Same shape, different counters. Operator-facing message: *"the only orchestrator with parent-enforced wall-clock + token + dollar kill."*

**Bet 3 — Ambient Stream Index + Schema Publication (Opportunity 5).**
INFRA-1973 (in queue) → SQLite-indexed ambient. Then publish `chump-agent-events-v1` spec. This is the moat play — define the observability schema for multi-agent before anyone else does.

### Wave 3 (4-8 weeks)

**Bet 4 — State.db Postgres Backend (Opportunity 1).**
The single-machine constraint on `state.db` is the C4 architectural finding. Postgres path is the smallest credible move that breaks the single-node ceiling. Sets up Bet 5.

### Wave 4 (8-12 weeks)

**Bet 5 — Local-LLM Mission Closure + Multi-Machine Routing (Opportunities 3 + 4 combined).**
Close the C1 mission-reality gap (productize MLX / Ollama as a real fleet backend, not just interactive-CLI). Stand up a second-machine NATS node. Wire capability-aware routing. **This is the demo that transforms Chump's narrative from "fleet for solo operator" to "local-first multi-agent coordination layer."**

This bet is multi-month and requires (a) the operator's second-machine hardware decision (Pi cluster? second M4 mini? phone-as-NPU?), and (b) the actual `ModelProvider` trait + MLX wiring in `src/dispatch.rs` (today: all paths default to `claude -p` cloud).

---

## Bounce-off-Roadmap: Questions for the Cross-Reference Pass

These are the questions to answer when reading this doc against `docs/ROADMAP_WAVES.md` + open-gap list:

1. **For each Bet — what gap IDs already exist?** I named some inline (INFRA-1970, 1971, 1972, 1973, 1974 from today's critique cascade). Are there others? Are any DONE-but-undocumented?

2. **Which Bets need NEW gap IDs filed?** The SWE-autonomy wrapper (Bet 1) doesn't have a gap I know of. The schema-publication step of Bet 3 doesn't have one. The Postgres backend of Bet 4 may or may not — needs lookup.

3. **What's already shipped that this doc doesn't credit?** I leaned on today's session work; there are 6+ months of substrate I don't have full visibility on (especially around the `chump-coord` crate, `chump-agent-lease`, `chump-messaging`). The bounce-off should surface "we already have X — re-narrate it."

4. **What's filed-but-stale?** Some of the older gaps (INFRA-1118 closed unmerged today during disk cleanup; INFRA-1323 local-merge-queue) may need re-scoping under the new Bet framework.

5. **What's the Mission Yield impact of each Bet?** Per `MISSION_YIELD.md`, the rule-of-X. Bet 1 (SWE wrapper) is probably the highest Yield-per-week-spent. Bet 5 is the highest absolute Yield but lowest Yield-per-week.

6. **Does any Bet conflict with the Marcus arc?** Marcus M-A through M-E milestones should be checked — Bet 1 likely accelerates M-B or M-C (depending on Marcus's current milestone state).

7. **What does the operator decide first?** The hardware question for Bet 5 (Pi vs second-M4 vs phone-as-NPU) is a multi-thousand-dollar decision the operator owns. That decision unlocks or constrains Bet 5's sizing.

## What This Doc IS / IS NOT

**IS:** strategic compass mapping the 5 white-space opportunities to specific Chump moves with concrete sizing. Sets up the next planning cycle.

**IS NOT:** a roadmap (see `ROADMAP_WAVES.md`). Not a complete priority re-ranking (operator owns the final order). Not committed plan — bounce-off step is mandatory before any Bet starts.

## Related Strategy Docs

- [`MISSION_YIELD.md`](MISSION_YIELD.md) — the headline number
- [`ROADMAP_WAVES.md`](ROADMAP_WAVES.md) — ship discipline
- [`ROADMAP_50_PER_HOUR.md`](ROADMAP_50_PER_HOUR.md) — capacity
- [`ROADMAP_MARCUS.md`](ROADMAP_MARCUS.md) — customer arc
- [`ARCHITECTURAL_CRITIQUE_2026-05-25.md`](ARCHITECTURAL_CRITIQUE_2026-05-25.md) — the 21-finding self-audit this doc references
- [`SHIP_ORDER_VISION_2026-05-25.md`](SHIP_ORDER_VISION_2026-05-25.md) — wedge-class ship topology
- [`THE_FLOOR.md`](THE_FLOOR.md) + [`FLOOR_RETROSPECTIVE.md`](FLOOR_RETROSPECTIVE.md) — substrate ratchet pattern this doc avoids repeating
