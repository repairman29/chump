# Rust infrastructure: where we are

Seven high-leverage items grounded in the Chump codebase. Status and design; implementation order is in [ROADMAP.md](ROADMAP.md) under "Rust infrastructure."

---

## 1. Tower middleware around every tool call — **Done (timeout + tool health + per-tool circuit + global concurrency + delegate preprocess)**

**Implemented:** `src/tool_middleware.rs`: `ToolTimeoutWrapper` applies a 30s timeout to every `execute()` and records timeout/errors to `tool_health_db` (status `degraded`). All tool registrations in Discord, CLI, and web builds use `wrap_tool(Box::new(...))`. **Per-tool circuit breaker:** after N consecutive failures (env `CHUMP_TOOL_CIRCUIT_FAILURES`, default 3) a tool is in cooldown for M seconds (`CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS`, default 60); during cooldown `execute()` returns "tool X temporarily unavailable (circuit open)" without calling the inner tool. On success the failure count for that tool is cleared. **Global concurrency (WP-3.1):** env **`CHUMP_TOOL_MAX_IN_FLIGHT`** (default `0` = unlimited) — `tokio::sync::Semaphore` limits concurrent `execute()` calls process-wide; **`GET /health`** includes **`tool_max_in_flight`** when set. **Per-tool rate limit (WP-3.2):** optional comma-separated **`CHUMP_TOOL_RATE_LIMIT_TOOLS`** (exact tool names). When set, each listed tool is limited to **`CHUMP_TOOL_RATE_LIMIT_MAX`** invocations (default 30) per **`CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS`** (default 60) **sliding window**; over-limit returns an error before the inner tool runs. **`GET /health`** includes **`tool_rate_limit`** JSON when configured. Unset tools list = no rate limiting (default). **DelegatePreProcessorWrapper (AUTO-012):** when `CHUMP_DELEGATE_PREPROCESS=1` and `CHUMP_DELEGATE_CONCURRENT=1`, any tool whose output exceeds `CHUMP_DELEGATE_PREPROCESS_CHARS` characters (default 4 000) is automatically summarised by the worker model (`run_delegate_summarize`, 5 sentences) before the main orchestrator receives the `ToolResult`. Fail-open: raw output returned if the worker summarise call fails. The wrapper is always constructed by `wrap_tool()` — the threshold check is a fast no-op when disabled. Wrap order: `inner → DelegatePreProcessorWrapper → ToolTimeoutWrapper`.

**Next (optional):** Full Tower `ServiceBuilder` stack (extra layers) with a `Service` adapter and `BoxCloneService` for type erasure — see roadmap.

---

## 2. Proc macro for tool boilerplate — **Done**

**Implemented:** `chump-tool-macro` crate (workspace member). Attribute macro `#[chump_tool(name = "...", description = "...", schema = r#"..."#)]` on an `impl Tool for T { async fn execute(...) { ... } }` block. Expands to a full impl with `name()`, `description()`, `input_schema()` (schema validated as JSON at compile time), and your `execute()`. Proof of concept: `calc_tool.rs` migrated; ~30 lines instead of ~80.

**Usage:** Put the attribute on the impl block that contains only `async fn execute`. Schema must be valid JSON (string; use `r#"..."#` for embedded quotes). Example:

```rust
use chump_tool_macro::chump_tool;

pub struct ChumpCalculator;

#[chump_tool(
    name = "calculator",
    description = "Perform arithmetic: add, subtract, multiply, divide. Params: operation, a, b.",
    schema = r#"{"type":"object","properties":{"operation":{"type":"string"},"a":{},"b":{}},"required":["operation","a","b"]}"#
)]
#[async_trait]
impl Tool for ChumpCalculator {
    async fn execute(&self, input: Value) -> Result<String> { ... }
}
```

**Next:** Migrate more tools to `#[chump_tool]` as they are touched; then inventory (item 3).

---

## 3. `inventory` (or `linkme`) for tool registration — **Done**

**Current state:** `inventory = "0.3"` in root `Cargo.toml`. `src/tool_inventory.rs` defines `ToolEntry { factory, is_enabled, sort_key }`, `inventory::collect!(ToolEntry)`, and `register_from_inventory(&mut ToolRegistry)` which iterates enabled entries (sorted by `sort_key`) and registers each via `tool_middleware::wrap_tool()`. All tools except `MemoryTool` are submitted in `tool_inventory.rs` via `inventory::submit! { ToolEntry::new(|| Box::new(X), "name").when_enabled(f) }` with env-based gating (e.g. `repo_path::repo_root_is_explicit`, `adb_enabled`, `delegate_enabled`). `discord.rs` creates the registry, calls `register_from_inventory(&mut registry)`, then registers `MemoryTool` manually (channel-specific). New tool = add one `submit!` in `tool_inventory.rs` (or later move to each tool file); no manual registry list.

**Next (optional):** Move each `inventory::submit!` into its corresponding tool file so "new tool = one file + one submit" is self-contained.

---

## 4. `tracing` with structured spans replacing `chump_log` — **Started (events in place)**

**Current state:** `tracing` and `tracing-subscriber` added; subscriber init in `main` (env filter from `RUST_LOG`). `agent_loop`: `agent_turn started` and `tool_calls start` / `tools completed` events with request_id, tools, duration_ms. `tool_middleware`: `#[instrument]` on `execute()` so each tool call is a span (tool name). `chump_log` retained (adjoin); no span DB yet.

**Next:** Optional subscriber layer → SQLite for span storage; introspect tool querying span DB; migrate more of chump_log to tracing over time.

---

## 5. Typestate session lifecycle — **Done**

**Current state:** `src/session.rs` defines `Session<S: SessionState>` with states `Uninitialized`, `Ready`, `Running`, `Closed`. `Session<Uninitialized>::new().assemble()` → `Session<Ready>` (holds assembled context); `Session<Ready>::start(self)` → `Session<Running>`; `Session<Running>::close(self)` → `Session<Closed>` (calls `context_assembly::close_session()` once). `chump_system_prompt(context: &str)` takes the context string; all agent builders create a session, assemble, and pass `session.context_str()`. CLI (`main.rs`) receives `(Agent, Session<Ready>)`, calls `.start()` before the run and `.close()` on exit (single-message or quit), so close cannot be called twice. Discord/Web build with a one-off session and drop it (no close). Impossible states (double close, tools before assemble) don't compile.

**Impact:** Correctness for overnight autonomous runs.

---

## 6. `notify` crate for real-time file watching — **Done**

**Current state:** `notify = "6"` in Cargo.toml. `src/file_watch.rs`: lazy-init `recommended_watcher` on `repo_path::repo_root()` when `repo_root_is_explicit()`; watcher runs in a spawned thread, sends paths to an mpsc channel; `drain_recent_changes()` returns paths (relative, deduped, .git filtered). `context_assembly::assemble_context()` calls `drain_recent_changes()` after the git-diff block and injects "Files changed since last run (live):" when non-empty. Near-zero CPU when idle; instant awareness on save between rounds.

**Impact:** Makes watch-style context real-time in addition to git diff at session start.

---

## 7. `rusqlite` connection pooling (r2d2) — **Done**

**Current state:** `r2d2` and `r2d2_sqlite` (0.25) in Cargo.toml. `src/db_pool.rs`: `OnceLock<Pool<SqliteConnectionManager>>`, path from `CHUMP_MEMORY_DB_PATH` or `current_dir()/sessions/chump_memory.db`. Manager uses `.with_init(|c| c.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"))`. Unified schema (all chump_memory tables) runs once at pool init. `db_pool::get()` returns a pooled connection. All DB modules (state_db, task_db, episode_db, schedule_db, ask_jeff_db, tool_health_db, memory_db) use the pool in production; `#[cfg(test)]` keeps direct `Connection::open` for test isolation.

**Impact:** Prevents SQLITE_BUSY under concurrent tool execution.

---

## Meta: sequencing

Items 1–3 compound: proc macro generates boilerplate, inventory auto-registers, Tower wraps execution. Suggested order (see ROADMAP):

1. **Tower stack** — immediate reliability and cost/health in one place.
2. **tracing migration** — observability and introspect for free.
3. **Proc macro** — then **inventory** — fast-tool-creation pipeline.
4. **Typestate sessions** — then **connection pool** — then **notify** — polish that compounds over time.
