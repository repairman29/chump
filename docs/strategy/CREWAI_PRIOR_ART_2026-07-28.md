# CrewAI as prior art — what to borrow, and how it maps to ChumpOS

> Filed 2026-07-28. Operator asked: "how is Chump different/same as CrewAI, and —
> we're Rust — can we still borrow from them?" This doc captures the answer and
> ties it to the [ChumpOS arc](../ROADMAP.md#the-chumpos-arc--the-multi-cycle-north-star-2026-07-27)
> (MISSION-065/066/067).

Reference: [github.com/crewaiinc/crewai](https://github.com/crewaiinc/crewai) —
"an open-source **Python framework** ... for building production-ready multi-agent
workflows." ~56k stars, 100k+ certified devs, an enterprise control plane (AMP Suite).

## 1. The framing: framework vs OS

The single sharpest distinction, and it is exactly the ChumpOS thesis:

- **CrewAI is a framework you use to *build* an agent team.** You import a Python
  library, define agents/tasks/crew in code, call `crewai run`, get an output. A
  bounded run you kicked off. The human is the **conductor** — they design the crew.
- **ChumpOS is an agentic *operating system* that runs itself.** It files its own
  work (gaps), claims it, writes code, passes real CI, merges PRs — across sessions
  and machines, no human authoring each task. The human is at **ring-0**, not in the
  conductor's chair (ROADMAP.md, ChumpOS arc).

In OS terms: **CrewAI is an application framework; ChumpOS is the operating system
that could *run* a CrewAI-style crew as one process.** That is not a put-down of
CrewAI — it is a precise statement of layer. They are not competitors; they sit at
different rings.

## 2. Same / different

**Genuinely the same** (the agent-execution layer overlaps — worth admitting):

| Concept | CrewAI | Chump / ChumpOS |
|---|---|---|
| Role-specialized agents | Agent(role, goal, backstory) | Curators/personas (shepherd, ci-audit, harvester, decompose…) |
| Delegation / handoff | Agent delegation | Typed handoff contracts (`crates/chump-handoff`) + A2A |
| Coordination modes | Sequential / hierarchical / Flows | Pull/push routing + A2A consensus |
| Tool use + local models | Ollama / LM Studio | ollama + llama-server on fleet nodes |
| Memory / state | Crew memory, Flow Pydantic state | state.db, ambient stream, lessons-store |

**Genuinely different** (why ChumpOS is not "CrewAI in Rust"):

1. **Running system vs library.** Kill the CrewAI process, the run is over. Kill a
   Chump worker, the farmer revives it and git+state.db carry the state forward.
2. **Nobody authors the orchestration.** Operator sets *outcomes*, not tasks; the
   system self-decomposes gaps and routes them.
3. **Output is shipped, CI-gated software** — a merged PR in a real repo, not a report.
4. **Distributed + self-healing** — two-node fleet over NATS+Tailscale, leases,
   reapers, farmer revival. CrewAI is in-process and ephemeral.
5. **Governance is the product.** The 4 pillars, outcome-gates on gap intake,
   reality-check-before-alarm, durable-fix doctrine, CI-parity gates — encoded from
   real incidents. CrewAI is a neutral framework; governance is bolt-on.
6. **Vertical vs horizontal.** CrewAI is general-purpose; ChumpOS is welded to
   software delivery (git/gh/CI/gaps).

The honest tension: a real slice of Chump's agent-*execution* layer (roles,
delegation, memory, local-model routing, tool use) is stuff CrewAI gives for free.
The novel delta is the **durable distributed fleet + git-native ship pipeline +
incident-encoded governance** — i.e. the *OS*, not the *crew*.

## 3. "We're Rust — can we still borrow?" Three flavors of borrow

**(a) Borrow the code — no.** It is Python; you cannot `cargo add crewai`. The only
code-reuse path is a **Python sidecar** behind a process boundary (the fleet already
shells out to git/gh/`claude -p`). Technically clean, but it drags a Python runtime
into a Rust-first, offline, local-LLM fleet — against the "own the stack, run
anywhere, no heavy deps" thesis. **Skip unless a specific bounded task earns it.**

**(b) Borrow the design — yes, this is the answer.** The abstractions are
language-agnostic and port straight into Rust:

- **Flows (typed event-state machine).** CrewAI's `@start`/`@listen`/`@router` +
  typed state → a clean model for *deterministic* multi-step orchestration. Chump
  coordinates via pull/push + consensus but has no crisp per-workflow state machine.
  Maps naturally to Rust enums + a typed state struct + serde. **Highest-value borrow.**
- **Typed `expected_output` on tasks.** Chump gaps carry free-text
  `acceptance_criteria`; CrewAI tasks return *typed* results. Tightening AC → a typed
  output contract is a real upgrade (serde-friendly).
- **`crew create` scaffolding UX.** Study for the founder-facing surface (`chump
  bootstrap` is the seed).

**(c) Borrow via interop — also yes, and most ethos-aligned.** CrewAI speaks MCP;
Chump already has `chump-mcp.json` + its own A2A. A Chump fleet and a CrewAI crew can
**cooperate over MCP** without either importing the other — CrewAI-built crews become
callable tools if ever wanted, Chump stays Rust.

**If you want *importable* code:** borrow from the **Rust** agent ecosystem
(`rig`, `swiftide`, `llm-chain`) — those you can actually vendor. CrewAI you *learn*
from; a Rust crate you *use*.

## 4. How each borrow maps onto the ChumpOS phases

| Borrow | ChumpOS home | Umbrella |
|---|---|---|
| **Flows → typed state machine** for deterministic multi-step gap execution + **typed task outputs** | **Phase 2: Kernel ABI — design-time contract enforcement** (A2A fires on invariant-reversal / privilege-spend / collision). Typed contracts ARE the ABI. | **MISSION-067** |
| **CrewAI-as-harness** (or any crew framework) meeting `HARNESS_CONTRACT.md` | The "swappable harnesses" powered-by layer; local-model lane | Phase 7 (giveable) |
| **MCP interop** with external crews | Harness/tool boundary; `chump-mcp.json` | ongoing |
| Scaffolding UX (`crew create`) | Founder-facing surface (`chump bootstrap`) | Phase 6 (userland) |

**The load-bearing link:** ChumpOS Phase 2 wants a *kernel ABI* — design-time
contract enforcement so agents cannot silently reverse invariants or collide (the
#3331 lesson). CrewAI's typed Task outputs + Flow state machines are the
best-in-class prior art for exactly that shape of typed, checkable, multi-step
contract. **We do not import CrewAI to get it; we port the pattern into the Rust
kernel ABI.** That is the highest-value, most ethos-aligned borrow, and it is
already on the roadmap as MISSION-067.

## 5. Recommendation

1. **Do:** port a **Flow-style typed state machine for multi-step gap execution**
   into the Rust kernel ABI (Phase 2 / MISSION-067). Scoped gap filed alongside this doc.
2. **Do:** keep the MCP interop door open so external crews are callable tools.
3. **Don't:** add a Python CrewAI runtime dependency to the fleet hot path.
4. **Watch:** the Rust agent crates (`rig` et al.) as the *importable* alternative
   when a piece genuinely wants a library, not a pattern.

Bottom line: being Rust does not block borrowing — it just means you borrow CrewAI's
**ideas** (Flows, typed outputs) and its **interop** (MCP) for free, and skip its
**code**. The framework/OS gap is not a thing to close; it is the ChumpOS thesis.
