# Chump upgrade roadmap: the "Claude" tier

**Context for Cursor agent:** This roadmap contains longer-horizon priorities to upgrade Chump's core inference, context management, editing capabilities, and (Phases 6–9) **proactive distributed operation**—sandboxing, fleet dispatch, structural memory, and briefing-style automation. Before beginning any task, review [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) and [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md). When a task is completed, mark the checkbox `[x]` in this file and add tests for the new behavior.

**Status:** Aspirational reference backlog. Items are not committed sprint work until checked off (and optionally mirrored in [ROADMAP.md](ROADMAP.md)). **Phases 1–5** skew toward reliability and context quality; **Phases 6–9** skew toward isolation, swarm/fleet parallelism, blackboard synthesis, and proactive workflows; **Phases 10–12** skew toward **enterprise-style resilience**: atomic session commits, provider watchdogs, strict tool validation and SLAs, and cross-node observability; **Phases 13–16** skew toward **speed** (North Star in [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md)): TTFT, KV/prefix reuse, async tool I/O, perceived-fast UI, and a **fast lane** for trivial prompts.

---

## Phase 1: Semantic context vs. lossy summarization

*Objective: Replace the naive summarization trigger with dynamic, verbatim semantic retrieval.*

### Implementation notes (repo alignment)

- **`CHUMP_CONTEXT_SUMMARY_THRESHOLD`** and related knobs (`CHUMP_CONTEXT_MAX_TOKENS`, `CHUMP_CONTEXT_VERBATIM_TURNS`, `CHUMP_MAX_CONTEXT_MESSAGES`) are defined and read in [`src/context_window.rs`](../src/context_window.rs). Token-based trim / summarization behavior is implemented in [`src/local_openai.rs`](../src/local_openai.rs) (message cap, threshold, delegate summarization path).
- [`src/context_assembly.rs`](../src/context_assembly.rs) assembles brain, soul, and session context for prompts; coordinate changes there with provider-side trimming in `local_openai.rs`.
- **Embeddings / retrieval:** Default HTTP embed service is **`CHUMP_EMBED_URL`** (often `http://127.0.0.1:18765`) — see [`src/memory_tool.rs`](../src/memory_tool.rs). The optional **`inprocess-embed`** Cargo feature ([`src/embed_inprocess.rs`](../src/embed_inprocess.rs)) is a separate in-process path. Phase 1.2 should specify which backend is queried and reuse existing semantic / FTS paths in [`src/memory_graph.rs`](../src/memory_graph.rs) and memory DB code after an audit (do not assume a single "RRF" API until verified).

- [x] **Task 1.1: Audit context assembly**
  - **Done:** [CONTEXT_ASSEMBLY_AUDIT.md](CONTEXT_ASSEMBLY_AUDIT.md) — Path A (`assemble_context`) vs Path B (`apply_sliding_window_to_messages`), env table, mermaid flow, gap vs Task 1.2 (FTS today vs embed/semantic target).

- [x] **Task 1.2: Implement sliding semantic window**
  - **Done:** [`apply_sliding_window_to_messages_async`](../src/local_openai.rs) after trim; optional **`CHUMP_CONTEXT_HYBRID_MEMORY=1`** uses [`memory_tool::recall_for_context`](../src/memory_tool.rs) (RRF: keyword + semantic + graph). Default off; **`CHUMP_CONTEXT_MEMORY_SNIPPETS`** caps lines. [`LocalOpenAIProvider`](../src/local_openai.rs) and [`MistralRsProvider`](../src/mistralrs_provider.rs) use the async path. Sync [`apply_sliding_window_to_messages`](../src/local_openai.rs) keeps FTS5-only memory for any non-async caller.

- [x] **Task 1.3: Context pruning tests**
  - **Done:** `sliding_window_trim_drops_oldest_when_over_hard_cap` and `sliding_window_async_inserts_notice_when_trimmed` in [`local_openai.rs`](../src/local_openai.rs) `#[cfg(test)]` (with `serial_test` for env isolation).

---

## Phase 2: Bulletproof edit capabilities

*Objective: Prefer unified-diff edits over fragile exact-string replacement, and give the model file context when a hard tool error occurs.*

### Implementation notes (repo alignment)

- **There is no `edit_file` tool in tree.** Committed docs/scripts should use **`patch_file`** / **`write_file`**. **`patch_file`** ([`PatchFileTool`](../src/repo_tools.rs)): single-file unified diff via [`src/patch_apply.rs`](../src/patch_apply.rs). On context mismatch the tool **still returns `Ok`** with a recovery message and numbered excerpt so the model can retry in the same turn. **`write_file`** / **`read_file`** / **`list_dir`** live in the same module. Registration: [`src/tool_inventory.rs`](../src/tool_inventory.rs).

- [x] **Task 2.1: Implement unified diff / AST parsing**
  - **Done:** `patch_file` with strict apply + parse errors surfaced as recovery text (not a wasted `Err` turn for mismatches). Optional future: line-range replace tool or AST-aware edits if product needs them.

- [x] **Task 2.2: Auto-correction loop on failure**
  - **Done:** Mismatch path: `patch_file` recovery message in [`repo_tools.rs`](../src/repo_tools.rs). Hard `Err` from `patch_file` / `write_file` / `read_file`: [`enrich_file_tool_error`](../src/repo_tools.rs) appends a numbered snippet of the target file when it exists; wired from [`task_executor.rs`](../src/task_executor.rs) (axonerai surfaces tool `Err` as `Tool error: …`). Optional future: bounded fuzzy match before returning (not implemented).

---

## Phase 3: Unchaining the autonomy loop

*Objective: Transition from a `max_iterations` while-loop to a persistent state machine driven by task rows.*

### Implementation notes (repo alignment)

- Multi-step work is already stored in SQLite table **`chump_tasks`** — schema and accessors in [`src/task_db.rs`](../src/task_db.rs). Web/API surfaces use `task_db` ([`src/web_server.rs`](../src/web_server.rs), [`src/autonomy_loop.rs`](../src/autonomy_loop.rs)).

- [ ] **Task 3.1: Create `TaskPlanner` tool**
  - Build a tool that allows the LLM to write a multi-step JSON plan into the `chump_tasks` table (or an adjunct table if you need steps as first-class rows).

- [ ] **Task 3.2: Refactor continuation logic in [`src/agent_loop.rs`](../src/agent_loop.rs)**
  - Replace or generalize `MAX_CONTINUATIONS` and the hardcoded `"Continue. Summarize progress..."` style continuation.
  - At turn start, read the active plan from the DB, execute only the next pending step, mark it complete, and yield.

---

## Phase 4: Enforcing "System 2" reasoning

*Objective: Reduce hallucination risk by forcing the model to emit structured reasoning before tool calls.*

### Implementation notes (repo alignment)

- Streaming / display stripping: [`src/agent_loop.rs`](../src/agent_loop.rs) (`strip_text_tool_call_lines` and related). Extend or add `strip_thinking_blocks` as needed.
- **Persistence:** Internal monologue should be stored for the agent (memory store / episode log). DB filenames vary by env — see [`src/memory_db.rs`](../src/memory_db.rs) and [`src/repo_path.rs`](../src/repo_path.rs); avoid hard-coding a single `chump_memory.db` name in code comments unless the project standardizes it.

- [x] **Task 4.1: Update system prompt architecture**
  - **Done:** [`CHUMP_THINKING_XML_PRIMACY`](../src/discord.rs) (with `CHUMP_THINKING_XML` off switch) mandates optional `<plan>` then required `<thinking>` before tools; [`peel_plan_and_thinking_for_tools`](../src/thinking_strip.rs) + [`agent_loop`](../src/agent_loop.rs) extract both for `thinking_monologue` / logging. Public UI still uses [`strip_for_public_reply`](../src/thinking_strip.rs).

- [x] **Task 4.2: Strip thinking blocks from UI**
  - **Shipped:** [`src/thinking_strip.rs`](../src/thinking_strip.rs) `strip_for_public_reply` removes `<thinking>`, `<plan>`, `<think>`, and legacy `think>` lines; [`src/discord.rs`](../src/discord.rs) `strip_thinking` delegates there; [`src/agent_loop.rs`](../src/agent_loop.rs) applies the same strip to `TurnComplete` / public display text after `strip_text_tool_call_lines`.
  - **Incremental (optional):** explicit dual-write of raw monologue into memory / episode tables only where product requires it — session `Message` content may still contain tags for model continuity.

---

## Phase 5: Weaponize delegate workers

*Objective: Prevent context pollution by pre-processing heavy tool outputs (e.g. `run_cli` compiler errors).*

### Implementation notes (repo alignment)

- **`CHUMP_WORKER_API_BASE`** / **`CHUMP_WORKER_MODEL`** are already used by delegate flows — see [`src/delegate_tool.rs`](../src/delegate_tool.rs) and [`src/memory_graph.rs`](../src/memory_graph.rs). A preprocessor likely hooks [`src/tool_middleware.rs`](../src/tool_middleware.rs) or the tool result path after execution.

- [ ] **Task 5.1: Create `DelegatePreProcessor` trait**
  - Hook into the tool execution pipeline. If a tool returns more than a configured token threshold of raw text, pause the main orchestrator for summarization.

- [ ] **Task 5.2: Route heavy output to `CHUMP_WORKER_API_BASE`**
  - Send raw output to the worker model with a strict extraction prompt; feed the concise result back as the `ToolResult` to the main orchestrator loop.

---

## Phase 6: Transactional tool sandboxing

*Objective: Tier-1 agents must not accidentally wipe directories. Chump needs stronger isolation for risky commands, moving beyond memory-only rollback in [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md).*

### Implementation notes (repo alignment)

- Speculative batch path: [`src/speculative_execution.rs`](../src/speculative_execution.rs), wiring in [`src/agent_loop.rs`](../src/agent_loop.rs). Blackboard snapshot/rollback hooks: [`src/blackboard.rs`](../src/blackboard.rs).
- **`run_cli` risk:** [`src/cli_tool.rs`](../src/cli_tool.rs) (`CliRiskLevel`, `heuristic_risk`). Policy and allowlists: [`src/tool_policy.rs`](../src/tool_policy.rs). Existing sandbox-oriented tool: [`src/sandbox_tool.rs`](../src/sandbox_tool.rs) (uses `CliRiskLevel::High` for WASM path — extend or add `sandbox_run` alongside).
- **Reality check:** True ephemeral containers on macOS/Termux are a large platform dependency; spike feasibility (Docker, `sandbox-exec`, WASM-only subset) before promising full bash-in-container for arbitrary commands.

- [ ] **Task 6.1: Implement `sandbox_run`**
  - Read [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) and extend the speculative execution model where it makes sense.
  - Add a tool that runs a **bounded** shell command in an isolated environment (WASM subset, container, or heavy `sandbox-exec` profile — pick after spike) and returns captured stdout/stderr without touching the host workspace until an explicit commit path.

- [ ] **Task 6.2: Auto-dry-run policy**
  - Update [`src/tool_policy.rs`](../src/tool_policy.rs) / [`src/agent_loop.rs`](../src/agent_loop.rs) so `CliRiskLevel::High` patterns (`rm`, `chmod`, `sudo`, etc.) route through sandbox / dry-run first when enabled.
  - If sandbox stderr indicates danger or mismatch, return that diagnostic to the model **before** surfacing a host `ToolApprovalRequest` for the same command.

---

## Phase 7: Full fleet map-reduce (the swarm)

*Objective: Stop serializing everything through the primary orchestrator. Use the local cluster (e.g. Mac + Pixel Termux node) for concurrent read/summarize work.*

### Implementation notes (repo alignment)

- Delegation today: [`src/delegate_tool.rs`](../src/delegate_tool.rs), worker env `CHUMP_WORKER_API_BASE` / `CHUMP_WORKER_MODEL`.
- **Pixel / Mabel:** Operational model and `peer_sync` **heartbeat round** (not yet a generic reducer over N worker futures) are documented in [MABEL_DOSSIER.md](MABEL_DOSSIER.md) and [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md). Task 7.2 should clarify whether "peer_sync aggregation" extends that round or introduces a new **job queue + collect** primitive shared with `task_db`.
- **Concurrency:** Any "5 concurrent read_file on Pixel" design must respect tool allowlists (`CHUMP_CLI_ALLOWLIST`), SSH/deploy paths in [OPERATIONS.md](OPERATIONS.md), and avoid duplicating Discord responses from multiple orchestrators.

- [ ] **Task 7.1: Upgrade `DelegateTool` for swarm dispatch**
  - Extend delegation to support **async batch** jobs (fan-out / fan-in) with explicit correlation IDs.
  - When `TaskPlanner` (Phase 3) or equivalent decomposes work (e.g. repo audit), dispatch parallel read/summarize shards to worker nodes while keeping the main session on the orchestrator model.

- [ ] **Task 7.2: Implement `peer_sync` aggregation (or successor)**
  - Add a **reducer** that merges worker outputs into one report, optionally ingests into memory FTS ([`src/memory_graph.rs`](../src/memory_graph.rs) / memory DB) for later retrieval.
  - Reconcile naming with today's **peer_sync** round semantics so docs and code stay coherent.

---

## Phase 8: Persistent blackboard and concept synthesis

*Objective: Long-term structural understanding of projects (rulesets, deploy configs) without stuffing raw chat into every prompt.*

### Implementation notes (repo alignment)

- Blackboard module: [`src/blackboard.rs`](../src/blackboard.rs) (GWT-style entries, salience, integration with context). Episodes: [`src/episode_db.rs`](../src/episode_db.rs) (and related). Memory Keeper role: scripts / launchd per [OPERATIONS.md](OPERATIONS.md) and ChumpMenu Roles tab — a **background extractor** likely hooks the same logs/episodes DB rather than only cron text.
- **Prefetch:** [`src/context_assembly.rs`](../src/context_assembly.rs) already composes brain + blackboard paths; Phase 8.2 adds **entity keyed** injection when project identifiers match stable blackboard keys (avoid accidental prompt bloat).

- [ ] **Task 8.1: Background entity extraction**
  - When the agent is idle (or on a Memory Keeper schedule), scan recent episodes and extract durable facts, project rules, and ADR-like decisions into **blackboard** entries (or a dedicated table keyed for synthesis).
  - Ensure writes are idempotent and size-bounded.

- [ ] **Task 8.2: Contextual pre-fetching**
  - Update [`src/context_assembly.rs`](../src/context_assembly.rs): when the user names a known project/entity, prefer the synthesized blackboard summary over generic semantic recall for that slot.
  - Keep token budget explicit (truncate with clear markers).

---

## Phase 9: Proactive "morning briefing" workflows

*Objective: Compute overnight and surface concise answers before the next user turn—Artifacts-style prep for Discord.*

### Implementation notes (repo alignment)

- **Sentinel / Shepherd:** Role scripts and launchd examples live under `scripts/` and [OPERATIONS.md](OPERATIONS.md); ChumpMenu starts/stops some heartbeats. Moving from "cron fires a script" to "event-driven observer" touches filesystem/git watchers ([`src/file_watch.rs`](../src/file_watch.rs) may be reusable) and/or GitHub webhooks — scope whether **local repo `git diff`** only vs remote events.
- **Discord push:** [`src/discord.rs`](../src/discord.rs) and web paths; **`diff_review`** exists as a tool — wire an **async** summary path that does not block the main reply pipeline; respect rate limits and `notify` / user DM policies.
- **Safety:** Uncommitted-change scans must not leak secrets from `.env`; avoid auto-posting huge diffs—delegate compress (Phase 5) applies.

- [ ] **Task 9.1: Event-driven Sentinel daemon**
  - Evolve Sentinel/Shepherd from fixed schedules toward **observers** (local `git status` / `git diff`, watched paths under repo roots in `CHUMP_GITHUB_REPOS`, optional GitHub API polling).
  - Persist observation state (cursor SHAs, last notified revision) in SQLite or small state files under `logs/`.

- [ ] **Task 9.2: Asynchronous Discord reporting**
  - After idle + dirty tree heuristics, run **`diff_review`** (or worker-compressed equivalent) and post a **short** morning summary to the active Discord channel or DM (configurable), including suggested tasks that land in `chump_tasks` when appropriate.

---

## Phase 10: Transactional state and crash recovery

*Objective: Survive host reboots, MLX/Ollama crashes, and OOM kills without corrupting session history or losing the current turn’s reasoning trail.*

### Implementation notes (repo alignment)

- **Session persistence:** [`src/agent_loop.rs`](../src/agent_loop.rs) uses `axonerai::file_session_manager::FileSessionManager` (see also [`src/discord.rs`](../src/discord.rs), [`src/main.rs`](../src/main.rs), [`src/spawn_worker_tool.rs`](../src/spawn_worker_tool.rs)). Atomic **SQLite** semantics for “whole turn” may span Chump’s memory/episode tables ([`src/memory_db.rs`](../src/memory_db.rs), [`src/episode_db.rs`](../src/episode_db.rs)) **and** axonerai’s on-disk session format—design whether one transaction boundary wraps both or a two-phase “write-ahead then commit” marker is needed.
- **Provider resilience:** Model health and circuit behavior live around [`src/local_openai.rs`](../src/local_openai.rs), [`src/provider_cascade.rs`](../src/provider_cascade.rs), and [`src/interrupt_notify.rs`](../src/interrupt_notify.rs). Autonomy entry points: [`src/autonomy_loop.rs`](../src/autonomy_loop.rs). “Pause + backoff + notify” should reuse existing notify/interrupt patterns where possible.

- [ ] **Task 10.1: Atomic turn commits**
  - Refactor [`src/agent_loop.rs`](../src/agent_loop.rs) and session persistence so a turn’s durable state (messages, tool results, belief updates where applicable) commits in **one** atomic boundary (SQLite `BEGIN IMMEDIATE` / single commit, or equivalent) only after the turn completes successfully.
  - On process death mid-turn, observers should see the **previous** consistent checkpoint (rollback or WAL discipline—pick after auditing current write ordering).

- [ ] **Task 10.2: Provider health watchdog**
  - Add a **pre-flight** (or middleware) health probe before expensive `provider.complete()` / cascade calls.
  - If Ollama / MLX / remote slot is down: pause autonomy (or degrade to safe mode), emit a **system notification** (Discord/web per existing channels), and apply **exponential backoff** retries until healthy—without silently corrupting partial tool state.

---

## Phase 11: Tool execution hardening

*Objective: Stop orchestrator spirals from malformed tool JSON or hung child processes.*

### Implementation notes (repo alignment)

- Tool registration and metadata: [`src/tool_inventory.rs`](../src/tool_inventory.rs), routing in [`src/tool_routing.rs`](../src/tool_routing.rs), execution and policy in [`src/agent_loop.rs`](../src/agent_loop.rs) + [`src/tool_middleware.rs`](../src/tool_middleware.rs).
- **`run_cli` / timeouts:** [`src/cli_tool.rs`](../src/cli_tool.rs) (risk heuristics, process spawn). Long builds may already stream or truncate—audit before changing defaults so CI-style commands do not false-fail.

- [ ] **Task 11.1: Strict schema enforcement pipeline**
  - Extend [`src/tool_inventory.rs`](../src/tool_inventory.rs) (or adjacent validation module) so every `ToolCall` payload is validated against a **JSON Schema** (or typed struct) **before** execution.
  - On validation failure, run a **bounded** auto-repair prompt (or deterministic fixer for common cases) that does **not** consume the main turn’s `max_iterations` budget—or account for it explicitly in metrics.

- [ ] **Task 11.2: Granular SLA timeouts**
  - Replace or supplement global timeouts with **per-tool** (or per-tool-class) SLAs (e.g. `web_search` short, `run_cli` long / dynamic based on command class).
  - For long `run_cli`, stream **stdout/stderr chunks** back to the model (or ring-buffer summaries) so the UI/agent does not assume failure on silence—coordinate with Discord/SSE limits.

---

## Phase 12: Swarm observability and telemetry

*Objective: One place to see latency, failures, and epistemic risk across Mac + Pixel + optional iPhone mesh—without manually tailing five logs.*

### Implementation notes (repo alignment)

- **Tracing today:** [`src/agent_loop.rs`](../src/agent_loop.rs) and other modules use `tracing`; exporter wiring may be minimal—audit `Cargo.toml` / init in [`src/main.rs`](../src/main.rs) or discord bootstrap.
- **Speculative metrics:** [`src/speculative_execution.rs`](../src/speculative_execution.rs) exposes `record_last_speculative_batch` (called from [`src/agent_loop.rs`](../src/agent_loop.rs)) and `last_speculative_metrics_json()` consumed by [`src/health_server.rs`](../src/health_server.rs) and [`src/pilot_metrics.rs`](../src/pilot_metrics.rs). A dashboard can start by **polling `/health`** or `/api/pilot-summary` before adding Prometheus.
- **Distributed trace IDs to shell workers:** Propagating W3C `traceparent` into `farmer-brown.sh` / `mabel-farmer.sh` requires SSH/env plumbing and script cooperation—treat as a **phase-2** sub-deliverable after in-process spans are solid.

- [ ] **Task 12.1: OpenTelemetry / tracing integration**
  - Expand `tracing::instrument` coverage on hot paths (agent loop, tool dispatch, provider calls).
  - Propagate a **trace ID** across delegate/SSH invocations where feasible; correlate with existing health and pilot JSON endpoints.

- [ ] **Task 12.2: Speculative execution dashboards**
  - Export speculative batch metrics (resolution, confidence/surprisal deltas where recorded—see `last_speculative_metrics_json` shape) to **Prometheus/Grafana** and/or a **small HTML dashboard** under `web/` or reuse PWA dashboard patterns.
  - **Goal:** Visually spot tool combinations with high surprisal / repeated rollback, then tune prompts or policy (`tool_policy`, ask sets) with evidence.

---

## Phase 13: Inference and prompt caching (MLX fast path)

*Objective: Cut wasted compute on the M4 (and similar) by reusing static prompt prefixes in the KV cache instead of re-encoding the full system + rules every turn.*

### Implementation notes (repo alignment)

- Provider stack: [`src/local_openai.rs`](../src/local_openai.rs), [`src/streaming_provider.rs`](../src/streaming_provider.rs), cascade in [`src/provider_cascade.rs`](../src/provider_cascade.rs). **Prefix / prompt caching** is **server-specific** (vLLM, Ollama, MLX servers expose different flags)—spike per slot before promising one code path.
- **Session stickiness:** Caching assumes stable session id + model id + provider base; document invalidation when soul, brain, or slot changes mid-session.

- [ ] **Task 13.1: System prompt and prefix caching**
  - Split “static” vs “per-turn dynamic” portions of the assembled context and pass caching hints (or ordered blocks) to backends that support prefix reuse.
  - Validate with metrics: time-to-first-token and total tokens billed per turn on long sessions.

- [ ] **Task 13.2: Speculative decoding (draft and verify)**
  - Prototype a **draft model** (small, local) + **verify model** (primary) pipeline where the stack supports it; fall back gracefully when the backend has no native speculative API.
  - Ensure tool-call boundaries and JSON safety are not broken by draft text (verify step must reject invalid tool JSON).

---

## Phase 14: Zero-blocking tool concurrency

*Objective: Decouple I/O-bound tools from the inference loop so the orchestrator is not idle while `read_url` / `web_search` / large reads complete.*

### Implementation notes (repo alignment)

- Central tool batching: [`src/agent_loop.rs`](../src/agent_loop.rs) (`execute_tool_calls_with_approval`, speculative batch paths). Tools live under `src/*_tool.rs` and [`src/tool_routing.rs`](../src/tool_routing.rs).
- **Streaming into context:** Today the model typically waits for full tool results; true mid-tool partial context injection may require **provider / session API** support or a staged “partial result” message type—flag as high-complexity design before committing.
- **Delegate offload:** [`src/delegate_tool.rs`](../src/delegate_tool.rs) + `CHUMP_WORKER_API_BASE`; Pixel offload must respect network, auth, and CHUMP_CLI_ALLOWLIST policies.

- [ ] **Task 14.1: Asynchronous tool streaming**
  - Refactor `execute_tool_calls_with_approval` so I/O-heavy tools can **emit progress** (chunks or summaries) over the existing event channel without blocking the next provider call where safe.
  - Start with **`read_url`** / **`web_search`**-class tools; define ordering guarantees (no speculative execution on partial tool state unless explicitly allowed).

- [ ] **Task 14.2: Background delegate offloading**
  - For very large text transforms (e.g. huge logs), **enqueue** work to the worker (`DelegateTool`) and return a handle; main loop **yields** with a clear “waiting on worker” state instead of blocking a tokio thread on remote I/O.
  - Coordinate with Phase 7 swarm dispatch so two designs do not fork.

---

## Phase 15: Perception of speed (UI and UX streaming)

*Objective: TTFT *perceived* under ~200ms: the client shows activity immediately, even if tools run for seconds.*

### Implementation notes (repo alignment)

- Event model: [`src/stream_events.rs`](../src/stream_events.rs), SSE wiring in [`src/web_server.rs`](../src/web_server.rs) (`/api/chat`), PWA under [`web/`](../web/). macOS menu client: [`ChumpMenu/`](../ChumpMenu/) (Swift Chat tab).
- **Phase 4 dependency:** Streaming `<thinking>` requires that Phase 4’s tags exist and are **sanitized for public channels** (strip for Discord/public web; optional stream for trusted UIs only).

- [ ] **Task 15.1: Real-time thought streaming**
  - Extend SSE / ChumpMenu parsers to surface **early internal reasoning** (collapsible, low-emphasis UI) as tokens arrive—without leaking secrets from tool stderr into that stream.
  - Measure **time-to-first-event** after POST `/api/chat`.

- [ ] **Task 15.2: Optimistic UI updates for tasks**
  - When task-create APIs succeed (or when a `TaskPlanner` tool commits), emit an **`AgentEvent`** (or parallel SSE envelope) so the PWA task list updates **before** `TurnComplete`.
  - Reconcile with server truth on failure (rollback optimistic row + toast).

---

## Phase 16: The short-circuit memory bypass

*Objective: Greetings, tiny clarifications, and “stop” commands should not pay for FTS, speculative batches, or full context assembly.*

### Implementation notes (repo alignment)

- Entry point for a single user turn: [`src/agent_loop.rs`](../src/agent_loop.rs) `run` (and web/discord wrappers). Context assembly: [`src/context_assembly.rs`](../src/context_assembly.rs). Heavy recall: [`src/memory_graph.rs`](../src/memory_graph.rs). Speculative path: [`src/speculative_execution.rs`](../src/speculative_execution.rs).
- **Classifier risk:** False “fast lane” routes skip safety checks—keep **tool policy** and **approval** gates mandatory for any path that can mutate disk or run shell.

- [ ] **Task 16.1: Intent-based fast lane**
  - Add a **cheap** intent gate at the start of `AgentLoop::run` (rules + tiny model or heuristic) to detect no-tool, low-risk prompts.
  - When matched, skip `memory_graph` retrieval and speculative batching; call a **small** completion model with a minimal system stub. Fall back to full orchestration on uncertainty or tool-like phrasing.

---

## Phase 8: Feature-flagged swarm architecture (the toggle)

*Objective: Build distributed task routing hooks behind a single global flag so the default M4 / local-primary path stays fast, while the codebase can scale to mesh workers (Mac + iPhone / Android nodes) when enabled.*

### Architecture strategy (definitive)

- **Single gate:** `CHUMP_CLUSTER_MODE=1` enables swarm-style routing (delegate + separate worker base). When unset or not `1`, the orchestrator behaves as **local-primary only**: `CHUMP_DELEGATE` and `CHUMP_WORKER_API_BASE` are ignored for routing decisions.
- **Mesh watchdog:** On first agent turn with cluster mode on, Chump probes the same HTTP endpoints as [`scripts/check-inference-mesh.sh`](../scripts/check-inference-mesh.sh) (`INFERENCE_MESH_MAC_URL` / `INFERENCE_MESH_IPHONE_URL`, defaults `:8000` and `:8889` `/v1/models`). If the probe fails, Chump logs a warning and stays on the local path for the process (no crash).
- **Executor abstraction:** Tool execution goes through [`AgentTaskExecutor`](../src/task_executor.rs) (`LocalExecutor` vs `SwarmExecutor`). [`ChumpAgent::run`](../src/agent_loop.rs) stays agnostic; both implementations currently share the same sequential approval + in-process `ToolExecutor` pipeline until farmer-brown / peer fan-out lands.
- **Metrics hygiene:** [`precision_controller::swarm_supplementary_metrics_enabled`](../src/precision_controller.rs) is false on the local-primary path so future mesh RTT / delegate-worker samples are not recorded there.

### Implementation notes (repo alignment)

- Global flag and trim helper: [`src/env_flags.rs`](../src/env_flags.rs) (`chump_cluster_mode`).
- Mesh probe + pending/up/down state: [`src/cluster_mesh.rs`](../src/cluster_mesh.rs).
- Delegate + worker base respect cluster/mesh: [`src/delegate_tool.rs`](../src/delegate_tool.rs), [`src/memory_graph.rs`](../src/memory_graph.rs).
- Executor trait + dispatch: [`src/task_executor.rs`](../src/task_executor.rs); [`src/agent_loop.rs`](../src/agent_loop.rs) calls `cluster_mesh::ensure_probed_once` at turn start.

- [x] **Task 8.1: Implement the global cluster toggle** (`CHUMP_CLUSTER_MODE`; local-primary ignores `CHUMP_WORKER_API_BASE` / `CHUMP_DELEGATE` when off or mesh down).
- [x] **Task 8.2: The `TaskExecutor` trait abstraction** (`AgentTaskExecutor`, `LocalExecutor`, `SwarmExecutor`; `dispatch_tool_execution` from `agent_loop`).
- [x] **Task 8.3: Graceful degradation (mesh watchdog)** (HTTP probe at startup of first turn; fallback with warning).
- [x] **Task 8.4: Feature-flagged metrics** (`swarm_supplementary_metrics_enabled`, `record_swarm_latency_hint` stub).

---

## Handoff reminder

Pick **one** unchecked task per Cursor run when implementing; add tests with the feature; then check the box here and mention the change in [ROADMAP.md](ROADMAP.md) if the project adopts the work as tracked delivery.
