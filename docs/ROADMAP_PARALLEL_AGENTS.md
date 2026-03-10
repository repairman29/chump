# Plan: Parallel Agents

This doc defines how Chump scales **workers** (the “chimps”) while keeping **one Chump** (one orchestrator, one identity, one process).

**Design principle:** **One Chump, as many chimps as he wants.** We do not want multiple Chump instances or a swarm of orchestrators. We want a single Chump who can spin up as many worker chimps (delegate calls) as he needs in parallel—summarize this, extract from that, translate the other—and get all results back in one go. Optional: safe concurrency so that one Chump handling many Discord messages at once doesn’t overload the model or the process.

**Relationship:** Builds on [ORCHESTRATOR_WORKER](ORCHESTRATOR_WORKER.md) and [ROADMAP](ROADMAP.md) pillar 6. This doc is the single place for the “many chimps” plan.

---

## Current state

| Dimension               | Today                                | Notes                                                                                                                                           |
| ----------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Orchestrator**        | One per Discord message (or CLI run) | Each message gets a `tokio::spawn`; inside that spawn, one agent run to completion.                                                             |
| **Worker (delegate)**   | One call per tool invocation         | Orchestrator calls `delegate` once per tool call; host runs one `provider.complete()` and returns. No batching.                                 |
| **Concurrent messages** | Yes, but independent                 | Two Discord messages → two spawns → two full agent runs. No shared queue or rate limiting; each has its own session.                            |
| **Multi-process**       | No                                   | Single rust-agent process. Multiple model servers (8000, 8001) are separate processes but used by one agent at a time (orchestrator vs worker). |

So: “parallel” today only means **multiple Discord messages can be in flight at once** (each its own agent run). There is **no** parallel execution of multiple workers in one turn, and no design for multiple coordinated agents (e.g. pool, swarm).

---

## What we’re building: one Chump, many chimps

1. **Many chimps (parallel workers in one turn)** — **Primary goal.** In one Chump turn, he may want to call `delegate` several times (summarize A, summarize B, extract from C). Today those run one at a time. We want them to run **in parallel** and return all results so Chump can use them in one go. One Chump; as many worker chimps as he asks for.

2. **Safe concurrency for that one Chump** — When many Discord messages hit at once, we still have **one** Chump (one process); each message is one of his “turns.” We want a cap (e.g. max 2–3 concurrent turns) so we don’t overload the model server or memory. Excess gets a “busy” response. Still one Chump; just bounded concurrency.

3. **Multiple Chump instances** — **Out of scope.** We are not building multiple orchestrators, multi-tenant Chumps, or a swarm of Chumps. If someone runs two rust-agent processes, that’s a deployment choice, not part of this plan. The plan below focuses on (1) and (2).

---

## Phase 1: Parallel workers (batch delegate in one turn)

**Goal:** When the orchestrator issues **multiple** `delegate` tool calls in a single turn, the host runs them **in parallel** (e.g. `join_all` or `futures::future::join_all`) and returns all results so the orchestrator can use them in one go.

### 1.1 AxonerAI / agent loop behavior

- The agent loop (AxonerAI) typically does: one completion → parse tool_calls → for each tool call, execute in sequence → append results → next completion. To run workers in parallel we need either:
  - **Option A:** AxonerAI supports “execute these N tool calls concurrently and return when all are done.” Then we pass a list of delegate calls and run them with `tokio::join_all` (or similar) in the delegate tool’s implementation. But the tool interface is “one input → one output,” so the **orchestrator** would have to issue one tool call per delegate (and the loop might still run them sequentially).
  - **Option B:** Introduce a **batch delegate** tool: one tool call with payload `{ "tasks": [ { "task_type": "summarize", "text": "..." }, { "task_type": "extract", "text": "..." } ] }`. The host runs all tasks in parallel and returns a single string (e.g. JSON array or numbered list). Orchestrator sees one tool call and gets all results.
  - **Option C:** Change the **agent loop** (or fork AxonerAI) so that when the completion returns N tool calls, we execute all of them concurrently (when safe) and then pass all results back in one round. That’s a bigger change and may not be in our control.

**Recommendation:** **Option B** — add a `delegate_batch` tool (or extend `delegate` with an optional `tasks` array). Schema: either one `task` (current behavior) or `tasks: [{ task_type, text, ... }]`. Execute with `futures::future::join_all` (or tokio equivalents), aggregate results (e.g. `["result1", "result2"]` or a single formatted string), return. Document: “Use delegate_batch when you need to summarize or extract from several texts at once; results are returned in order.”

### 1.2 Implementation sketch

- In `delegate_tool.rs` (or a new `delegate_batch_tool.rs`):
  - If input has `tasks` (array): for each task, spawn a task that runs the same worker logic (provider.complete). `tokio::join_all` (or `futures::future::join_all`) on the list of futures. Map results to a single string (e.g. one per line, or JSON array).
  - If input has single-task fields (`task_type`, `text`): keep current behavior (one worker call).
- **Concurrency limit:** Optional `CHUMP_DELEGATE_MAX_PARALLEL` (e.g. 4) so we don’t fire 20 workers at once. When `tasks.len() > limit`, run in chunks of `limit` and concatenate results.
- **Error handling:** If one worker fails, options: (a) return partial results + error line for the failed one, (b) fail the whole batch. Prefer (a) so the orchestrator can still use successful results.

### 1.3 Docs and prompt

- Update [ORCHESTRATOR_WORKER](ORCHESTRATOR_WORKER.md): add “Parallel workers (batch)” section; document `delegate_batch` (or extended `delegate`) and `CHUMP_DELEGATE_MAX_PARALLEL`.
- System prompt: “When you need to summarize or extract from several texts in one go, use delegate_batch (or delegate with tasks array) so the host can run them in parallel.”

**Exit criteria:** One orchestrator turn can trigger multiple worker completions in parallel; results aggregated and returned; limit and error behavior documented.

---

## Phase 2: Safe concurrent orchestrator turns

**Goal:** Multiple Discord messages (or CLI invocations) can run at the same time without overloading the model server or memory; add simple rate limiting and backpressure.

### 2.1 Current behavior

- Discord: each message → `tokio::spawn(agent.run(...))`. Many messages → many concurrent agent runs, each holding session state and calling the same model server. No limit on concurrent runs.
- Risk: 10 users each send a long message → 10 concurrent 30B requests → vLLM queue or OOM; or one process memory spike.

### 2.2 Design: semaphore or queue

- **Option A — Semaphore:** Global semaphore (e.g. `Arc<Semaphore>`) with permit count = 2 or 3. Before running the agent in the Discord handler, `acquire().await`; when the run finishes, release. So at most N concurrent agent runs.
- **Option B — Bounded queue:** Incoming messages go into a channel; a fixed number of worker tasks pull and run the agent. Messages beyond the channel capacity can be rejected or deferred (“queue full, try again in a minute”).
- **Option C — Per-channel or per-user limit:** Limit concurrent runs per channel (or per user) so one channel can’t starve others. More complex; can come after A or B.

**Recommendation:** **Option A** first. Config: `CHUMP_MAX_CONCURRENT_TURNS` (default 2 or 3). When the semaphore is full, either (a) wait (with a timeout) and then reply “busy, try again,” or (b) reply immediately “I’m at capacity; try again in a moment.” Prefer (b) so the Discord gateway doesn’t hold too many connections.

### 2.3 Implementation sketch

- In `discord.rs`: create `Arc<Semaphore>::new(permits)` (from env or default). In the message handler, before `build_agent` and `agent.run`, do `semaphore.clone().acquire_owned().await` (or try_acquire with timeout). If we can’t acquire in e.g. 5s, reply with a busy message and return. When the spawn finishes (success or error), the permit is dropped. Same pattern can apply to CLI if we ever run multiple CLI sessions in one process.
- **Logging:** Log when we reject due to capacity so operators can tune.

**Exit criteria:** At most N concurrent agent runs (configurable); excess gets a clear “busy” response; doc and env var.

---

## Phase 3: Optional extras (still one Chump)

We are **not** building multiple Chump instances. The following are optional and only if we need them later.

- **Per-channel config (same Chump):** Optional override of system prompt or tool set per channel (e.g. “Chump-dev” in one channel). Same process, same identity; different tone or tools per channel. Document only unless we have a use case.
- **Multi-process (out of scope):** Running multiple rust-agent processes (e.g. one per repo) is a deployment choice, not part of the “one Chump, many chimps” plan. No code or design required for it here. If someone runs two processes, they get two Chumps; that’s on them.
- **Worker pool (separate processes):** A dedicated “chimp pool” process that only runs delegate tasks and pulls from a queue could scale workers horizontally. Defer unless we hit limits with in-process parallel workers (Phase 1).

---

## Summary

| Phase | Focus                                      | Deliverables                                                                                                                              |
| ----- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **1** | Many chimps (parallel workers in one turn) | `delegate_batch` (or extended `delegate` with `tasks`); run workers with `join_all`; `CHUMP_DELEGATE_MAX_PARALLEL`; doc and prompt update |
| **2** | Safe concurrency for one Chump             | Semaphore for max concurrent turns; `CHUMP_MAX_CONCURRENT_TURNS`; “busy” when at capacity                                                 |
| **3** | Optional extras                            | Per-channel config if needed; multi-process and worker-pool explicitly out of scope for “one Chump”                                       |

**Principle:** One Chump, as many chimps as he wants. Phase 1 and 2 deliver that; Phase 3 is optional and does not add a second Chump.

**Links:** [ORCHESTRATOR_WORKER](ORCHESTRATOR_WORKER.md), [ROADMAP](ROADMAP.md) §6, [MEMORY_AND_PROCESSES](MEMORY_AND_PROCESSES.md) (memory pressure when many concurrent runs).
