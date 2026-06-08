# A2A / Fleet-Coordination Master Plan (2026-06-03)

> **Status:** operator-commissioned ("make it working, the BEST we can literally build it, deploy asap").
> **Supersedes the framing of:** `docs/design/A2A_ROADMAP.md` (META-061) — that roadmap built the *primitives*; this plan turns them on and upgrades them to state-of-the-art.
> **Also subsumes:** the "CI self-audit pivot" (the over-coupled-CI deadlock that ate the 2026-06-03 session). The reliability tier here *is* that fix. They are one problem.
> **Backed by three research lanes (2026-06-03):** frontier A2A protocols, frontier multi-agent frameworks, and an exhaustive survey of Chump's existing A2A. Source links at the bottom.
> **See also (2026-06-08):** [`A2A_COORDINATION_RESEARCH_2026-06-08.md`](./A2A_COORDINATION_RESEARCH_2026-06-08.md) — frontier validation of this plan + cutting-edge refinements (DOC-067), after the CREDIBLE-122 tally fix proved the loop could finally close.

---

## 0. The one-sentence diagnosis

**Chump's A2A is a fully-built publish bus with zero subscribers.** ~15 coordination primitives exist as working, tested code — mesh, inboxes, 6 typed contracts, RPC types, scratchpad, capability manifests, work-board, consensus — and **almost none are load-bearing**, because they're gated behind two env flags that have never been set and have no subscribe-side / no call-sites / no inbox-drain.

It didn't take forever to *build*. It was built. **Nobody turned it on.** The fix is therefore *fast*: flip the switches (Tier 0), then upgrade to state-of-the-art (Tier 1).

Evidence (from the survey):
- `chump-coord assign` publishes **1,277 work-envelopes / 30s to nobody** — no `chump-coord worker` subscribes.
- `CHUMP_A2A_LAYER=1` (subscribe side) and `CHUMP_FLEET_RECV_SIDE_V0=1` (fan-out + voting + tally) — **never set.**
- Inboxes fill (822 in the operator's) — **no loop calls `chump-inbox.sh read`.**
- 6 typed contracts (`crates/chump-handoff/src/contracts.rs`) — **zero production call-sites.**
- RPC (`crates/chump-coord/src/rpc.rs`) — a stub that returns `NotImplemented`.
- Scratchpad, capability manifests — code + tests exist, **never called.**

---

## 1. Target architecture — the best A2A we can build

Seven layers, each pulling the strongest idea from the frontier and mapping to what Chump already has. (Steal-list grounded in the research.)

### L1 — Identity & Discovery: signed capability cards + skill taxonomy
- **Steal:** A2A **Agent Cards** at `/.well-known/agent-card.json`, JWS-signed (kills ghost-agent routing); AGNTCY **OASF** 3-axis skill taxonomy (`skills` / `domains` / `modules`) for *capability-aware* matching instead of free-text.
- **Chump has:** Layer 2c capability manifests (`capability.rs`, `publish_manifest`, `heartbeat_loop`) — built, **never published**. The KV bucket `chump_capabilities` is empty.
- **Do:** publish manifests on worker start; add the skill taxonomy; the picker queries "agent with `skills⊇{rust,sqlite}`, `domain=INFRA`, `load<80%`" before awarding.

### L2 — Task model: the 8-state machine with `input_required`
- **Steal:** A2A's task state machine — the missing states are **`input_required`** ("70% done, need an operator decision, then I resume" — *not* failed) and **`auth_required`** (the exact failure mode that killed this fleet for 46h).
- **Chump has:** flat gap statuses (open/claimed/done/blocked). No "suspended, awaiting input" state.
- **Do:** add gap status `waiting_operator` + a structured question payload; `chump gap respond <ID> --answer '{...}'` resumes. Kills the "agent over-autonomously guesses wrong OR gives up and files a follow-up gap" dichotomy.

### L3 — Assignment: Contract-Net bidding + tuple-space steal + budget law
- **Steal:** Contract Net **CFP→BID→AWARD** (fitness-scored, not first-come); Linda/blackboard **`in()`** atomic work-stealing; Agent-Contracts **budget conservation** (`Σ child_budget ≤ parent_budget` for tokens / CI-min / disk).
- **Chump has:** first-available pull from SQLite + atomic NATS-KV claim. No fitness signal, no budget propagation (an orchestrator can spawn 10 subagents at full budget = 10× burn).
- **Do:** 5-second bid window; award score = `w1·skill_match + w2·(1/load) + w3·class_success_rate`; enforce the budget law at `chump gap decompose` time. (Research: budget law gave 90% token reduction, zero violations / 50 trials.)

### L4 — Messaging semantics: ontology tags + performatives
- **Steal:** FIPA-ACL's `:ontology`/`:language` + **performatives** (intent separated from content). A2A's own analysis flags this as its unsolved gap: it routes tasks but can't ensure agents *agree what "approved PR" means.*
- **Chump has:** free-text `kind` strings on ambient events; no schema-version pinning across concurrent `chump-coord` versions.
- **Do:** add `schema_version: "chump-vN"` to every event; receiver emits `kind=schema_mismatch` rather than silently misinterpreting.

### L5 — Coordination bus: event sourcing + push notifications  ★ highest impact
- **Steal:** **Event sourcing** — upgrade `ambient.jsonl` from write-only telemetry to a typed domain-event log on NATS JetStream with **subscriptions + `corr_id` sagas**. Agents *react* (`gap.claimed`→overlap-scan, `test.failed`→ci-audit, `pr.merged`→ship) instead of broadcasting into the void. Plus A2A **push notifications (JWT+JWKS webhooks)** so agents stop *polling* CI — one signed POST when a PR reaches terminal state; the agent claims other work meanwhile.
- **Chump has:** NATS publish (working) + the assign daemon (publishing to nobody). The substrate is right; it's "push hint" today, needs to become "durable event log with subscriptions."
- **Do:** this is the conversion of "wired" → "load-bearing." Subscribers + typed subjects + saga compensation by `corr_id`.

### L6 — Reliability: durable execution + supervision trees + guardrails  ★ = the CI pivot
- **Steal:** **Durable execution** (Temporal/DBOS) — each gap = a journaled workflow; every LLM call a retried *activity*; crash → resume from journal, no lost context, no re-claim-from-scratch. (DBOS-style = SQLite/Postgres-native, zero new infra.) **Supervision trees** (Erlang/OTP) — per-gap restart-intensity (3/5min → mark blocked + escalate); fleet supervisor (>2 escalations/10min → pause pickup + health-check). **Guardrail pre-commit agents** (OpenAI SDK) — a gate agent validates scope/paths/gap-id *before* the main agent writes.
- **Chump has:** lease-expiry-and-reclaim (loses all context); no transient-vs-systematic distinction; off-rails enforced only at the git hook (post-hoc).
- **Do:** **this layer is the fix for the chronic CI-deadlock retry-storm hydra.** Supervision-tree escalation would have caught today's loop on cycle 4 instead of cycle 30. Build it; it ends the firefighting class.

### L7 — Shared state: typed reducer blackboard
- **Steal:** LangGraph **typed reducer state** (`Annotated[list, add]` append-only; last-writer-wins-with-timestamp) + CAS; blackboard/Linda tuple-space as the shared medium.
- **Chump has:** the scratchpad (`scratchpad.rs`, file-backed get/set/cas, 5 seed keys) — built, **never read or written.**
- **Do:** make each gap's in-flight state a typed reducer object (SQLite JSON blob + version counter + read-then-CAS); activate the scratchpad as the fleet blackboard (`main.head.sha`, `fleet.size`, `last_known_good`).

---

## 2. TIER 0 — turn on what's built (deploy THIS WEEK, ~80% of the value, mostly config)

| # | Move | Unblocks | Effort |
|---|---|---|---|
| 0.1 | `CHUMP_FLEET_RECV_SIDE_V0=1` in launchd env | FEEDBACK fan-out + deliberator tally + voting (META-157, design-complete) | flag |
| 0.2 | `CHUMP_A2A_LAYER=1` + start `chump-coord worker` | the subscribe side — 1,277-envelope flood gets consumers; push routing replaces sqlite-poll | flag + daemon |
| 0.3 | `chump-inbox.sh read` as the **mandatory first step** of every curator/worker loop | inboxes drained + acted on | ~10 LOC × loops |
| 0.4 | Route the spawn path through the typed contracts (`agent_factory.rs` / `chump gap decompose` → `DecomposeContract`/`CodeFixContract`/`GapReviewContract`) | typed handoffs replace free-form markdown; typed output → state.db | s |
| 0.5 | Ship RPC slice 2/4 (`rpc.rs::call_rpc` returns `NotImplemented`) | `ask-eta` / `ask-overlap` / `ask-handoff` work; unblocks L3e deliberation | m |
| 0.6 | Run `capability-publish.sh` per worker start | discovery/routing (L1) gets data | flag + plist |
| 0.7 | Start the Mode-A integrator OR drain the 110 stranded `ship-ready` work-board items | the work-board stops being a dead-letter office | ops |

**Gate:** after 0.1–0.3, verify on the mesh: `consensus_result` events fire, `inbox_advance` count > 0, FEEDBACK proposals reach quorum. That's the "load-bearing" proof.

---

## 3. TIER 1 — state-of-the-art build (prioritized; each is a real gap)

Priority order = impact:
1. **L6 reliability (supervision trees + durable execution + guardrails)** — *also kills the CI-deadlock class.* Do first.
2. **L5 event-sourcing coordination bus** — converts the whole thing from telemetry to reactive coordination.
3. **L2 task `input_required`** — the "suspended not failed" state; high operator-experience payoff.
4. **L3 Contract-Net bidding + budget law** — smarter, budget-safe assignment.
5. **L1 signed cards + OASF taxonomy** / **L4 ontology tags** / **L7 reducer blackboard** — hardening + correctness.

**Explicitly do NOT adopt** (from the research): CrewAI hierarchical delegation (sequential-masquerading-as-routing, 30–50% token tax); full Raft/Paxos for claims (SQLite-WAL + advisory locks suffice <100 workers); CRDTs for *coupled* code edits (CodeCRDT: 39.4% slowdown on shared-dependency tasks — disjoint files only); LangGraph checkpointing *as a durability story* (not durable execution — needs an external watchdog).

---

## 4. The convergence — why this is also the CI fix

The two things on fire this session — **A2A dormant** and **the CI self-audit deadlock hydra** — are **one problem**: no subscribers + no supervision + no durable execution = agents that can neither coordinate nor self-heal. Tier-1 L6 (supervision + self-rescue) is precisely the "make the fleet able to dig out of its own red trunk" capability it provably lacks today (every red-trunk this session required a human with `--admin`). Build L6 and the firefighting class ends.

---

## 5. Deployment plan — soup-to-nuts, gap-indexed

Umbrella: **MISSION-009**. Existing gaps are *referenced/unblocked* (NOT duplicated); the new frontier gaps were filed 2026-06-03.

> **⚠️ VERIFIED 2026-06-03 — this callout supersedes the "mostly config / flip 2 flags / deploy today" tone of M1 below.** I ran the runtime instead of trusting the gap-DB. Ground truth:
> - **Live & working:** `chump-coord assign` daemon (publishing every 30s), broadcast→inbox fan-out (111 inbox files), `chump consensus-tally` (read-only verdict math — produced a correct `NO_QUORUM` on a live proposal).
> - **Built but GATED OFF:** `chump vote` (flag unset → "vote not emitted" → proposals starve for quorum; only **1 of 12** inbox proposals has any votes).
> - **Built but BROKEN:** the deliberator auto-tally daemon (`deliberator-loop.sh tick`) crashes on bad shell arithmetic and has **never once emitted a `consensus_result`** (count = 0, ever). Filed as **RESILIENT-061** — the keystone; Sonnet dispatched 2026-06-03.
> - **Not running:** `chump-coord worker` (subscribe side). RPC (`call_rpc`) confirmed a `NotImplemented` stub (INFRA-1119).
>
> **Corrected M1 sequence:** (1) land **RESILIENT-061** so a tick emits `consensus_result`; (2) finish the small recv-side slices **META-163** (xs), **META-159/162** (m — CLIs already work); (3) THEN flip `CHUMP_FLEET_RECV_SIDE_V0=1` (enables voting) + start the deliberator daemon. Flipping the flag *before* the fix only accumulates un-tallied votes. Consensus has **literally never completed** — the last mile is one bug + one flag, not a flag-flip alone. **GATE:** `consensus_result` count goes 0 → ≥1 on a real proposal.

### M0 — Unblock (now)
- **Operator nod:** make the over-coupled `audit` gate non-required / diff-scoped → land the stuck 12-PR queue. (L6 self-rescue rebuilds it properly in M2.)
- Commit this doc + the gaps.

### M1 — Tier 0: turn on what's already built (days; almost entirely config)
| Gap | Action | State today |
|---|---|---|
| **INFRA-1120** | ship the capability-manifest (A2A Layer 2c) | **ready_to_ship — just ship it** |
| **META-157 / INFRA-2515** | set `CHUMP_FLEET_RECV_SIDE_V0=1` + `CHUMP_A2A_LAYER=1` in launchd env | open |
| *(config)* | start `chump-coord worker` — the subscribe side (the 1,277-envelope flood gets consumers) | not running |
| **INFRA-1119** | ship RPC slice 2/4 (`call_rpc` → real, not `NotImplemented`) | open |
| **INFRA-1825** | activate the CapabilityManifest publish loop per worker | open |
| **INFRA-1797 / 1798 / 2016**, fix **INFRA-2495 / 2006** | wire `chump-inbox.sh read` as the mandatory FIRST step of every loop | open |
- **GATE (proves "load-bearing"):** `consensus_result` fires, `inbox_advance` > 0, `chump_capabilities` KV populated, RPC works.

### M2 — Tier 1 L6 reliability (week) — *also the CI-deadlock fix*
- **RESILIENT-058** supervision trees · **RESILIENT-059** durable execution · **RESILIENT-060** guardrail pre-commit gate.
- **GATE:** a red trunk auto-recovers via supervision/self-rescue **without a human `--admin`** (the thing every red-trunk this session required).

### M3 — Tier 1 L5 coordination bus
- **EFFECTIVE-037** event-sourcing bus (typed subjects + subscriptions + `corr_id` sagas).
- **GATE:** an agent reaction fires from a subscription, with no polling loop.

### M4 — Tier 1 remainder
- **EFFECTIVE-038** L2 task-states (`input_required`/`auth_required`) · **EFFECTIVE-039** L3a Contract-Net bidding · **ZERO-001** L3b budget-conservation law · **CREDIBLE-087** L4 ontology tags · **INFRA-1123** L1 signed cards · **INFRA-1826** L7 scratchpad/reducer · **INFRA-1122** L3e deliberation (needs RPC from M1).

Each milestone is independently shippable and independently valuable. M2 alone ends the firefighting that ate this session.

---

## 6. Research sources (2026 frontier)
- **Protocols:** Google A2A (`a2a-protocol.org/latest/specification/`, LF-governed, 150+ orgs); MCP (`modelcontextprotocol.io/specification/2025-11-25`); IBM ACP (merged into A2A 2025-08); AGNTCY/OASF (`docs.agntcy.org`); FIPA-ACL (`fipa.org/specs/fipa00003`); Contract Net + Agent Contracts (`arxiv.org/html/2601.08815`); Blackboard/Linda (`lia.disi.unibo.it/~ao/pubs/pdf/1999/spe.pdf`).
- **Frameworks:** AutoGen/AG2; LangGraph; Temporal/Restate/DBOS (`diagrid.io/blog/checkpoints-are-not-durable-execution`); Erlang/OTP supervision; OpenAI Agents SDK guardrails; event sourcing / CRDT (`arxiv.org/pdf/2510.18893`).
- **Chump current state:** survey 2026-06-03 — `crates/chump-coord/{assign,rpc,capability,scratchpad}.rs`, `crates/chump-handoff/src/contracts.rs`, `scripts/coord/{broadcast,deliberator-loop,capability-publish}.sh`, `docs/design/A2A_ROADMAP.md`, `docs/gaps/META-157.yaml`.
