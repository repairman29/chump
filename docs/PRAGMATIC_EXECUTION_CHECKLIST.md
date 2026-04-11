# Pragmatic execution checklist (local-first, swarm-gated)

Consolidated checklist for execution order: stabilize single-node inference and context **before** distributed work. High-risk swarm paths stay behind **`CHUMP_CLUSTER_MODE`** (see [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phase 8 and [`src/cluster_mesh.rs`](../src/cluster_mesh.rs)).

---

## Phase 1: Engine stability and the “token diet”

*Prevent the M4 from swapping to disk and stabilize the core inference loop.*

- [ ] **Lock single-node configuration (operator):** In `.env`, remove or comment out `CHUMP_FALLBACK_API_BASE` and `CHUMP_WORKER_API_BASE`. Set `CHUMP_DELEGATE=0` (or omit delegate). With **`CHUMP_CLUSTER_MODE` unset or `0`**, the binary already ignores worker/delegate for routing; keeping `.env` clean avoids accidental opt-in. See [OPERATIONS.md](OPERATIONS.md) and [.env.example](../.env.example).
- [ ] **Throttle vLLM concurrency (operator):** Set `VLLM_MAX_NUM_SEQS=1` and `CHUMP_MAX_CONCURRENT_TURNS=1` in `.env` to reduce OOM risk during heavy multi-tool turns. See [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md), [STEADY_RUN.md](STEADY_RUN.md).
- [ ] **Implement semantic truncation:** Rework fallback logic in [`src/context_assembly.rs`](../src/context_assembly.rs) (with [`src/context_window.rs`](../src/context_window.rs) / provider trim). Replace or narrow the `CHUMP_CONTEXT_SUMMARY_THRESHOLD` summarization pass with **SQLite FTS5** retrieval for middle turns (align with [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phase 1).
- [ ] **Enforce aggressive eviction:** Evict or down-rank context slices (e.g. project rules, blackboard entities) not referenced in the last **N** turns (e.g. 3) to protect the context window; coordinate with any prefix/KV caching strategy ([ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phase 13 when server hints exist).

---

## Phase 2: Telemetry and baselines

*Prove upgrades reduce wasted turns and CLI thrash before heavy editor refactors.*

- [ ] **Expand the controller:** Extend [`src/precision_controller.rs`](../src/precision_controller.rs) with an automated benchmark or regression harness (turns-to-resolution, tool error counts, regime transitions). See [METRICS.md](METRICS.md).
- [ ] **Establish the baseline (procedure):** Run a fixed ambiguous scenario (e.g. broken build) in a clean session; record turns, `run_cli` errors, and time-to-green. Store numbers in the episode log or a doc under `logs/` / pilot notes for A/B comparison.

---

## Phase 3: Unchaining the autonomy loop

*Move from a reactive continuation loop to a plan-driven state machine.*

- [ ] **Build `TaskPlanner`:** Tool (or structured path) that writes a multi-step JSON plan into **`chump_tasks`** ([`src/task_db.rs`](../src/task_db.rs)). See [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phase 3.
- [ ] **Refactor `agent_loop.rs` continuation:** Remove or generalize `MAX_CONTINUATIONS` and the hardcoded `"Continue. Summarize progress..."` user message ([`src/agent_loop.rs`](../src/agent_loop.rs)).
- [ ] **Implement step-execution:** At turn start, read the active plan from the DB, execute **one** pending step, mark it complete, yield ([`src/autonomy_loop.rs`](../src/autonomy_loop.rs) may share patterns).

---

## Phase 4: Enforcing “System 2” reasoning

*Reduce premature tools and malformed tool JSON.*

- [ ] **Mandate thinking blocks:** System prompt update so the model emits `<thinking>` / `<plan>` (or equivalent) **before** native tool calls ([`src/discord.rs`](../src/discord.rs) / web server system prompt assembly).
- [ ] **Mask internal monologue:** Strip `<thinking>` / `<plan>` / redacted blocks from **public** Discord and web `TurnComplete` text; keep raw turns where the agent should retain them ([`src/thinking_strip.rs`](../src/thinking_strip.rs), [`src/agent_loop.rs`](../src/agent_loop.rs)). Persist unstripped content in memory/episodes as appropriate ([`src/memory_db.rs`](../src/memory_db.rs)).
- [ ] **Strict schema validation:** Validate tool JSON against registered schemas **before** execute (tighten beyond current pre-checks in [`src/tool_input_validate.rs`](../src/tool_input_validate.rs)); optional zero-cost retry path for malformed payloads ([`src/tool_inventory.rs`](../src/tool_inventory.rs) / tool registration).

---

## Phase 5: Bulletproof editing

*Prevent destructive refactors from exact-string fragility.*

- [ ] **Deprecate string matching:** Narrow or retire naive `edit_file` exact `old_str` in favor of safer flows ([`src/repo_tools.rs`](../src/repo_tools.rs)).
- [ ] **Implement diff tool:** Add `patch_file` (unified diff or line-range protocol). See [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phase 2.
- [ ] **Auto-correction hook:** On edit failure in [`src/agent_loop.rs`](../src/agent_loop.rs), fetch context (e.g. ±50 lines), bounded fuzzy match / Levenshtein assist, then return a concise diagnostic to the model.

---

## Phase 6: The “swarm” toggle (feature flagging)

*Prepare Pixel/iPhone nodes without polluting Mac-only success metrics.*

- [x] **Implement the global flag:** `CHUMP_CLUSTER_MODE` (default off) in [`src/env_flags.rs`](../src/env_flags.rs); routing rules in [`src/cluster_mesh.rs`](../src/cluster_mesh.rs).
- [x] **Abstract the executor:** Rust trait **`AgentTaskExecutor`** (named to avoid clashing with axonerai’s `ToolExecutor`) in [`src/task_executor.rs`](../src/task_executor.rs).
- [x] **Build `LocalExecutor`:** Sequential M4 path: approval + in-process `ToolExecutor` in `task_executor.rs`.
- [x] **Build `SwarmExecutor`:** Same sequential path today; reserved for async Tailscale map-reduce / farmer-brown style routing.
- [x] **Implement mesh watchdog:** `ensure_probed_once` probes Mac/iPhone `/v1/models` (configurable URLs); on failure degrades to local-primary and logs a warning. See Phase 8 in [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md).

---

## Handoff

Execute **one** unchecked box per focused PR when possible; run `cargo test` and `cargo clippy -- -D warnings`. After shipping a phase item, check the box here and optionally mirror into [ROADMAP.md](ROADMAP.md) if it becomes committed sprint work.
