# CHUMP: The "Cowork" Tier Upgrade Plan — agent handoff

**For Cursor and other AI coding assistants:** Read this file **first** when working on Cowork-tier upgrades. **Strictly adhere to the phase gates** — do not skip phases. Do not build distributed Swarm logic (network hops, Tailscale sync) until **Phase 6** is explicitly authorized.

**Before coding:** Read [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) and [`src/agent_loop.rs`](../src/agent_loop.rs). Optimize for **Apple Silicon M4** unified memory constraints.

**Target architecture:** Autonomous, SQLite-backed state machine with local semantic memory and strict reasoning requirements.

---

### Phase 1: Engine Stability & Context Truncation

**Objective:** Prevent MLX Metal OOM crashes and replace lossy summarization with exact semantic retrieval.

* **Target Files:** `.env.example`, `src/context_assembly.rs`, `src/context_window.rs`
* **Tasks:**
    1.  **Hardcode Safe Defaults:** Update `.env.example` to enforce `VLLM_MAX_NUM_SEQS=1` and `CHUMP_MAX_CONCURRENT_TURNS=1`. Ensure `CHUMP_DELEGATE=0` is set by default.
    2.  **Semantic Sliding Window:** Locate the `CHUMP_CONTEXT_SUMMARY_THRESHOLD` logic in `src/context_assembly.rs`. Deprecate the LLM summarization call.
    3.  **FTS5 Injection:** Implement a query to the `inprocess-embed` server to fetch verbatim chunks from older turns using semantic RRF. Replace the middle of the context window with these exact chunks.
    4.  **Aggressive Cache Eviction:** Update the prefix caching logic to forcefully evict any static `blackboard` entity or project rule that has not been referenced in the last 3 turns.

---

### Phase 2: Telemetry & Benchmark Baselines

**Objective:** Build an automated measurement tool to prove hallucination reduction before changing core agent behavior.

* **Target Files:** `src/precision_controller.rs`, `scripts/run-battle-sim-suite.sh`
* **Tasks:**
    1.  **Benchmark Harness:** Expand `precision_controller.rs` to track "Turns to Resolution" and "Total CLI Errors."
    2.  **Ambiguous Task Test:** Create a mock broken project state (e.g., a simple Rust project with a hidden syntax error and missing dependency).
    3.  **Automated Execution:** Write a script (`run-battle-sim-suite.sh`) that triggers the agent to solve the broken project, logs the metrics, and stores the baseline in `logs/battle_baselines.txt`.

---

### Phase 3: The Autonomy State Machine

**Objective:** Move away from reactive `while` loops and string-based continuation prompts. Implement a true step-by-step executor.

* **Target Files:** `src/task_tool.rs` (new), `src/agent_loop.rs`, `src/task_db.rs`
* **Tasks:**
    1.  **The `TaskPlanner` Tool:** Build a native tool that accepts a JSON array of objectives and writes them to the `chump_tasks` SQLite table with statuses (`pending`, `active`, `complete`, `blocked`).
    2.  **Refactor `agent_loop.rs`:** Remove `MAX_CONTINUATIONS` and the hacky `"Continue. Summarize progress..."` message injection.
    3.  **Turn Initialization:** Modify the run loop so that upon starting, it queries `chump_tasks`. If an active plan exists, the agent is prompted *only* with the next pending step and the previous step's result.

---

### Phase 4: System 2 Reasoning & Strict Schemas

**Objective:** Force the orchestrator model to compute its logic sequentially before emitting JSON, drastically cutting hallucination rates.

* **Target Files:** `src/agent_loop.rs`, `src/tool_inventory.rs`, `src/stream_events.rs`
* **Tasks:**
    1.  **System Prompt Update:** Inject a strict mandate requiring the model to wrap its internal logic in `<thinking>` XML tags immediately before executing any `ToolCall`.
    2.  **UI Masking:** Update the text parsing in `src/agent_loop.rs` (e.g., `strip_text_tool_call_lines`) to strip `<thinking>` blocks from the Discord and Web UI output, while ensuring they are still saved to `chump_memory.db`.
    3.  **Strict Validation:** Upgrade `tool_inventory.rs` to run strict JSON Schema validation on all incoming tool arguments. If a validation error occurs, catch it and feed the exact schema violation back to the LLM automatically, bypassing the user UI.

---

### Phase 5: Bulletproof Code Editing

**Objective:** Stop the agent from corrupting files with naive string replacements.

* **Target Files:** `src/repo_tools.rs`, `src/task_executor.rs` (see also `docs/ROADMAP_CLAUDE_UPGRADE.md` Phase 2)
* **Status (repo today):**
    1.  **`edit_file` removed** — no `EditFileTool` in tree; prompts and docs should say **`patch_file`** / **`write_file`**.
    2.  **`patch_file` shipped** — single-file unified diff in `src/repo_tools.rs` + `src/patch_apply.rs`; mismatch returns recovery text (soft fail).
    3.  **Hard-error context** — `enrich_file_tool_error` in `src/repo_tools.rs` + `task_executor.rs` appends numbered file excerpts on `Err` for repo file tools. **Optional later:** bounded fuzzy match before return (not implemented).

---

### Phase 6: Feature-Flagged Swarm Architecture

**Objective:** Lay the groundwork for Pixel/iPhone delegation, but isolate it completely from the primary M4 execution path.

* **Target Files:** `src/env_flags.rs`, `src/task_executor.rs` (new trait), `src/agent_loop.rs`
* **Tasks:**
    1.  **Global Toggle:** Add `CHUMP_CLUSTER_MODE` (default `0`) to `env_flags.rs`.
    2.  **Trait Abstraction:** Create a `TaskExecutor` trait. Move the existing synchronous execution logic into a `LocalExecutor` implementation.
    3.  **Swarm Scaffold:** Create a `SwarmExecutor` implementation that handles async map-reduce logic across Tailscale IPs.
    4.  **Mesh Watchdog:** Implement a startup check. If `CHUMP_CLUSTER_MODE=1`, ping the worker nodes. If they are unresponsive, log a warning and automatically downgrade to the `LocalExecutor` to prevent the agent from hanging.

---

## Implementation status (repo, for agents)

| Phase | Status |
|-------|--------|
| **1–5** | Not complete per this document; implement in order when authorized. |
| **6** | **Partially shipped:** `CHUMP_CLUSTER_MODE`, mesh watchdog, and executor abstraction live under [`src/env_flags.rs`](../src/env_flags.rs), [`src/cluster_mesh.rs`](../src/cluster_mesh.rs), [`src/task_executor.rs`](../src/task_executor.rs) (trait is named **`AgentTaskExecutor`** to avoid clashing with axonerai’s **`ToolExecutor`**), and [`src/agent_loop.rs`](../src/agent_loop.rs). Swarm map-reduce across Tailscale is still a scaffold only — do not expand until Phase 6 is explicitly authorized beyond the current flag + watchdog. |

Cross-reference: [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) Phase 8, [PRAGMATIC_EXECUTION_CHECKLIST.md](PRAGMATIC_EXECUTION_CHECKLIST.md).
