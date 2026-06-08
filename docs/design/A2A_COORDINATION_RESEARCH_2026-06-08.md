# A2A Coordination — 2026 Frontier Research & Validation

**Date:** 2026-06-08
**Gap:** DOC-067
**Companion to:** [`A2A_MASTER_PLAN_2026-06-03.md`](./A2A_MASTER_PLAN_2026-06-03.md) (the 7-layer design) · umbrella **MISSION-009**
**Why this exists:** before investing more in the A2A demand-side, we validated the approach against the genuinely current (2025–2026) multi-agent-coordination frontier — to ensure we are building cutting-edge *and* effective, not reinventing or shipping behind the state of the art.

---

## 0. Context — the bug this research followed

The A2A consensus layer had emitted **0 `consensus_result` events fleet-wide, ever**, despite ~49 "done" A2A gaps and **57 proposals broadcast over 24 days**. Root cause (fixed in **CREDIBLE-122**, PR #3099): the deliberator could not tally votes cast by the real `chump vote` tool (votes land as `kind=vote` in `ambient.jsonl` but the tally read `kind=vote` from `feedback.jsonl`, where the same vote is mirrored as `kind=preference`). The machine literally could not close the loop.

With closure fixed, the remaining problem is the **demand side**: agents broadcast proposals but never *read or vote on* each other's messages — coordination capability exists but is never exercised. This document validates the planned demand-side fixes against the frontier.

---

## 1. Executive summary

**The diagnosis is confirmed by the literature.** Every major framework — Google A2A, LangGraph, AutoGen/AG2, OpenAI Agents SDK, AWS Bedrock — treats message *consumption* as the **caller's responsibility, not a protocol guarantee**. "Messages pile up unread" is not a misconfiguration; it is the *designed default everywhere*. Forcing coordination requires deliberate architectural work no mainstream framework provides out of the box.

**What we already got right** (the single highest-impact design choice): our deliberator is a **deterministic vote aggregator** (`consensus-tally`, Rust), not an LLM. Five independent findings say an LLM-deliberator is wrong — it amplifies sycophancy, hallucinates consensus, duplicates what majority-voting already achieves, and is a single point of failure.

**Genuinely novel + sound:** the "refuse-tool-calls-until-inbox-drained" hook (CREDIBLE-114) has **no direct prior art** in the agent-fleet literature; closest analogs are LangGraph's `interrupt()` and Erlang's selective-`receive`.

### Three highest-impact changes
1. **Keep the deliberator a deterministic fold; never an LLM.** (Already true — preserve it. Reserve LLM deliberation only for no-quorum disagreement, then debate-then-vote with anti-sycophancy controls.) → MISSION-009 note, CREDIBLE-122.
2. **The inbox-drain gate must be the harness's job, not a prompt convention** — and it must *drain-then-proceed* (snapshot + process current messages, then unblock), **not block-until-empty** (which livelocks). → CREDIBLE-114.
3. **Add response-required tracking with SLA escalation** — close the "message read but silently ignored" gap that A2A, LangGraph, and AutoGen all leave open. → **EFFECTIVE-229** (newly filed).

---

## 2. Mapping — findings → implementing gaps

| Finding | Gap | Status |
|---|---|---|
| Deterministic tally (not LLM deliberator) | CREDIBLE-122 / MISSION-009 | ✅ done / validated |
| Harness-level inbox-drain gate, drain-then-proceed | CREDIBLE-114 | refinement folded into AC |
| Mandatory drain+act every loop cycle | INFRA-1798 | AC concretized |
| Response-required + SLA (read-but-ignored gap) | **EFFECTIVE-229** | newly filed |
| Contract-Net + epsilon-greedy + resource budgets | EFFECTIVE-039 | refinement folded in |
| Event-sourced bus + consumer-group offsets + idempotency | EFFECTIVE-037 | refinement folded in |
| Task-state machine + `input_required` SLA timeout | EFFECTIVE-038 | refinement folded in |
| Budget-conservation law for delegated work | ZERO-001 | aligned (Agent Contracts) |

---

## 3. Frontier survey

### 3.1 Google Agent2Agent (A2A) protocol (v1.0, 2025)
- **Task lifecycle states:** `submitted`, `working`, `input_required`, `auth_required`, `completed`, `failed`, `canceled`, `rejected`. The interrupted states (`input_required`/`auth_required`) are genuine pause points — the task halts and cannot resume without a client continuation on the same `taskId`. **Our EFFECTIVE-038 matches this exactly.**
- **What it does NOT provide:** no mandatory ACK ("Messages MUST NOT be considered a reliable delivery mechanism for critical information"), no dead-letter queue, no enforcement that a client agent polls/responds. If the caller ignores `input_required`, **the task hangs forever** — A2A has *no timeout*. SSE streaming is best-effort.
- **Lesson:** these states are *signaling, not enforcement*. → we must add an SLA timeout (EFFECTIVE-038) and response tracking (EFFECTIVE-229).
- Sources: [A2A spec](https://a2a-protocol.org/latest/specification/) · [Life of a Task](https://a2a-protocol.org/latest/topics/life-of-a-task/) · [Beyond Message Passing, arXiv 2604.02369](https://arxiv.org/pdf/2604.02369)

### 3.2 MCP for agent-to-agent
MCP is a hub-and-spoke **tool-invocation** protocol (JSON-RPC), not a peer coordination bus — no inbox, no pub/sub, no unsolicited peer messages. Used for coordination only as a capability-discovery / tool-call layer (one agent calls another's capability as a "tool"); zero consumption guarantees beyond synchronous call-response. **Verdict: not fit as a peer bus.** Sources: [Protocol survey, arXiv 2505.02279](https://arxiv.org/pdf/2505.02279) · [MCP for multi-agent, arXiv 2504.21030](https://arxiv.org/html/2504.21030v1)

### 3.3 Multi-agent frameworks — consumption guarantees
- **LangGraph** — the only mainstream framework with genuine consumption *enforcement*: `interrupt()` / breakpoints pause the graph at a node, checkpoint durably, and refuse to advance until `Command(resume=...)`. Closest production analog to our CREDIBLE-114 gate (but triggered by the agent, not an external invariant).
- **AutoGen / AG2** — GroupChat injects full conversation history into every agent's context; consumption is guaranteed by *shared-context injection*, not a mailbox. Cost: ≥20 LLM calls for a 4-agent/5-round debate.
- **OpenAI Agents SDK (Mar 2025)** — handoffs transfer full context to the receiving agent; consumption is implicit. Failure mode: multiple handoffs in one turn → only the last is used.
- **Magentic-One (Microsoft)** — orchestrator + Task/Progress ledgers, one subtask per inner loop, stall detection + replan. Most supervisory, but relies on the orchestrator LLM detecting stalls; documented failure: agents repeatedly fail the same step without intervention.
- Sources: [LangGraph interrupts](https://langchain-ai.github.io/langgraph/cloud/how-tos/human_in_the_loop_breakpoint/) · [Frameworks 2026](https://gurusup.com/blog/best-multi-agent-frameworks-2026) · [Magentic-One](https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/)

### 3.4 Classical distributed patterns — fit for LLM agents
- **Contract Net Protocol** — good fit for task allocation. LLM-CNP (COALESCE) shows 20.3% cost reduction via epsilon-greedy bidding; Agent Contracts add resource-bounded governance (token budgets). Limitation: CNP assumes agents *will* bid; it doesn't force them. → EFFECTIVE-039 / ZERO-001.
- **Actor model (Erlang/OTP mailboxes)** — strongest conceptual fit. Durable mailbox + **selective receive** (process only relevant messages). Must be enforced at the *harness* level (the LLM's prompt handler = the mailbox; one message per invocation), since LLMs can't block on `receive`. → CREDIBLE-114.
- **Event sourcing / Sagas (Temporal)** — production-proven durable execution; crash-replay from checkpoint, saga compensation by `corr_id`. Caveat: guarantees durable execution, *not* forced inbox-drain. → EFFECTIVE-037.
- **FIPA-ACL** — overkill; its formal performative ontology waned. Keep only the schema insight (performative types: request/inform/propose/agree/refuse). ECMA's NLIP (Dec 2025) is the natural-language successor.
- **Blackboard** — implicit in LangGraph shared-state + Magentic-One ledgers; not a consumption-enforcement mechanism on its own.
- Sources: [COALESCE, arXiv 2506.01900](https://arxiv.org/pdf/2506.01900) · [Agent Contracts, arXiv 2601.08815](https://arxiv.org/html/2601.08815v1) · [Actor model for LLMs](https://dzone.com/articles/actor-model-agentic-llm-apps) · [Temporal + AI](https://intuitionlabs.ai/articles/agentic-ai-temporal-orchestration)

### 3.5 "By default" — forced-consumption patterns
**No exact named prior art** for "refuse tool calls until inbox drained" in the 2025–2026 agent literature. Closest: LangGraph `interrupt()` (agent-triggered), TraceFix's TLA+ "channel drainage" invariant (a *postcondition*, not a pre-action gate), Erlang `receive` (language-scheduler level), Sentinel agents (after-the-fact quarantine). The pattern is **architecturally sound** with clear distributed-systems analogs (circuit breakers, admission control, TCP flow control).

**Documented failure modes + mitigations** (fold into CREDIBLE-114):
1. **Livelock** — A's inbox holds B's msg, B's holds A's reply, both blocked. → *Drain* received messages; never *block on sent-message replies*.
2. **Cascade flooding / alert fatigue** — a noisy sender outpaces drain → fleet permanently blocked. → inbox TTL auto-archival + sender rate-limit.
3. **Priority inversion** — a low-priority msg blocks a high-priority tool call. → priority tiers; drain P0/P1, let P2 accumulate.

**Critical design rule:** the gate must **drain-then-proceed** (snapshot current inbox, process it, unblock), *not* block-until-empty (the livelock path). Sources: [TraceFix, arXiv 2605.07935](https://arxiv.org/html/2605.07935v1) · [Durable-execution patterns](https://zylos.ai/research/2026-02-17-durable-execution-ai-agents)

### 3.6 Consensus / voting among LLM agents
- **Majority voting alone accounts for most of multi-agent debate's gains** (arXiv 2508.17536). Debate doesn't improve expected correctness without deliberate design.
- **Sycophancy is structural and compounding** — 18/20 agent pairs show peer-deference bias that *amplifies* across rounds; homogeneous (self-debate) is worst (arXiv 2604.02668, 2510.07517).
- **What works:** independent generation + majority vote (reasoning tasks, +13.2%); debate-then-vote hybrid (2–3 rounds) for complex decisions; confidence-weighted voting (ReConcile). Anti-sycophancy (CONSENSAGENT, ACL 2025): isolated reasoning before seeing peers, **response anonymization**, counter-argument forcing before vote, silent-convergence prohibition.
- **Quorum:** 3–5 agents is the practical sweet spot (diminishing returns past 5); `N ≥ 3f+1` for adversarial settings.
- **Design flaw to avoid:** an LLM deliberator is itself a sycophancy point. → keep the tally a **deterministic aggregation function** (we do). Sources: [Debate or Vote, arXiv 2508.17536](https://arxiv.org/pdf/2508.17536) · [CONSENSAGENT, ACL 2025](https://aclanthology.org/2025.findings-acl.1141.pdf) · [Identity bias, arXiv 2510.07517](https://arxiv.org/html/2510.07517v1)

---

## 4. Per-fix assessment

| Fix | Gap | Verdict | state-of-the-art form / what we added |
|---|---|---|---|
| (a) Refuse tool calls until inbox drained | CREDIBLE-114 | Sound + **novel** | Harness-level, **drain-then-proceed** (not block-until-empty), priority tiers, sender `read_at` receipt |
| (b) Mandatory `inbox read` first step | INFRA-1798 | Correct but **insufficient alone** | Enforce in harness, not prompt; tag `response_required` vs informational |
| (c) Contract-Net bidding | EFFECTIVE-039 | Correct pattern | + epsilon-greedy exploration, + resource-budget contracts, + no-bid dead-letter escalation, + auction log |
| (d) Event-sourced bus | EFFECTIVE-037 | Production-proven | + consumer-group offsets, + idempotency keys, + dead-letter topic; deliberator = durable deterministic fold |
| (e) Task state machine | EFFECTIVE-038 | Matches A2A exactly | + **SLA timeout** on `input_required` → auto-fail (A2A has none); wire to inbox as P0 |

**Missing piece, now filed (EFFECTIVE-229):** response-required tracking. Every message carries `response_required` + a deadline; the harness detects "consumed but no response emitted" and converts a silent drop into a `coordination_stalled` event with replay + escalation. This closes the gap A2A/LangGraph/AutoGen all leave open and is the exact failure that killed our 57 proposals even when surfaced.

---

## 5. Sources

> **Provenance + caveat:** these were gathered via an automated web-research pass (2026-06-08, Sonnet + web search) and have **not been individually re-verified** — spot-check any specific arXiv ID before treating it as load-bearing. The *findings* (A2A task-state model, LangGraph `interrupt()`, sycophancy in multi-agent debate, Contract-Net cost results, "majority voting captures most of debate's gains," forced-consumption having no named prior art) are each corroborated across multiple independent sources; individual citation IDs may drift.

- Google A2A: [spec](https://a2a-protocol.org/latest/specification/) · [life of a task](https://a2a-protocol.org/latest/topics/life-of-a-task/) · [arXiv 2604.02369](https://arxiv.org/pdf/2604.02369)
- Protocol surveys: [arXiv 2505.02279](https://arxiv.org/pdf/2505.02279) · [MCP multi-agent, arXiv 2504.21030](https://arxiv.org/html/2504.21030v1)
- Frameworks: [LangGraph interrupts](https://langchain-ai.github.io/langgraph/cloud/how-tos/human_in_the_loop_breakpoint/) · [2026 comparison](https://gurusup.com/blog/best-multi-agent-frameworks-2026) · [Magentic-One](https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/)
- Classical patterns: [COALESCE/CNP arXiv 2506.01900](https://arxiv.org/pdf/2506.01900) · [Agent Contracts arXiv 2601.08815](https://arxiv.org/html/2601.08815v1) · [Actor model](https://dzone.com/articles/actor-model-agentic-llm-apps) · [Temporal](https://intuitionlabs.ai/articles/agentic-ai-temporal-orchestration) · [RAPS arXiv 2602.08009](https://arxiv.org/pdf/2602.08009)
- Forced consumption: [TraceFix arXiv 2605.07935](https://arxiv.org/html/2605.07935v1) · [Durable execution](https://zylos.ai/research/2026-02-17-durable-execution-ai-agents)
- Consensus/voting: [Debate or Vote arXiv 2508.17536](https://arxiv.org/pdf/2508.17536) · [CONSENSAGENT ACL 2025](https://aclanthology.org/2025.findings-acl.1141.pdf) · [Identity bias arXiv 2510.07517](https://arxiv.org/html/2510.07517v1) · [Sycophancy propagation arXiv 2604.02668](https://arxiv.org/html/2604.02668) · [Council Mode arXiv 2604.02923](https://arxiv.org/pdf/2604.02923)

> **Honest caveat (per CREDIBLE-090 / reality-check doctrine):** these gaps are *specified*, not *shipped*. "Done" for this cluster is the OUTCOME — `consensus_result` climbing organically once the fleet runs and agents vote — not a green check or a closed gap. Verify the number, not the marker.
