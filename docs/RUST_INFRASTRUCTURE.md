# Rust infrastructure: where we are

Seven high-leverage items grounded in the Chump codebase. Status and design; implementation order is in [ROADMAP.md](ROADMAP.md) under "Rust infrastructure."

---

## 1. Tower middleware around every tool call — **Done (timeout + tool health)**

**Implemented:** `src/tool_middleware.rs`: `ToolTimeoutWrapper` applies a 30s timeout to every `execute()` and records timeout/errors to `tool_health_db` (status `degraded`). All tool registrations in Discord, CLI, and web builds use `wrap_tool(Box::new(...))`. No per-tool timeout logic; one place for future layers.

**Next (optional):** Full Tower `ServiceBuilder` stack (concurrency limit, rate limit, circuit breaker, tracing layer) with a `Service` adapter and `BoxCloneService` for type erasure — see roadmap.

---

## 2. Proc macro for tool boilerplate — **Not started**

**Current state:** Every tool repeats ~40 lines: `name()` → string, `description()` → string, `input_schema()` → hand-written `json!({...})`. Example: `git_tools.rs` (GitCommitTool) lines 68–86. No compile-time schema validation.

**Target:** Derive macro (e.g. `#[derive(Tool)]` + `#[tool(name = "...", description = "...")]` + schema from doc comments or attributes). Generates `name()`, `description()`, `input_schema()`. New tools: ~30 lines of logic instead of ~80.

**Effort:** ~1.5 days for proc macro crate. Pays off by the 4th tool.

---

## 3. `inventory` (or `linkme`) for tool registration — **Not started**

**Current state:** `discord.rs` builds the registry with a long manual list: `registry.register(Box::new(GitCommitTool));` etc. Same pattern in `build_chump_agent_web_components`. Every new tool requires editing the registry; "forgot to register" is a real bug class.

**Target:** Each tool file does `inventory::submit! { ToolEntry::new(|| Box::new(MyTool)) }`. Registry builds from `inventory::iter::<ToolEntry>()` with optional env-based `is_enabled()`. New tool = one file + one submit line; no central registration.

**Effort:** ~0.5 day. **Impact:** Eliminates registration bugs; makes self-discovery (Chump writes its own tool file) viable.

---

## 4. `tracing` with structured spans replacing `chump_log` — **Started (events in place)**

**Current state:** `tracing` and `tracing-subscriber` added; subscriber init in `main` (env filter from `RUST_LOG`). `agent_loop`: `agent_turn started` and `tool_calls start` / `tools completed` events with request_id, tools, duration_ms. `tool_middleware`: `#[instrument]` on `execute()` so each tool call is a span (tool name). `chump_log` retained (adjoin); no span DB yet.

**Next:** Optional subscriber layer → SQLite for span storage; introspect tool querying span DB; migrate more of chump_log to tracing over time.

---

## 5. Typestate session lifecycle — **Not started**

**Current state:** `context_assembly.rs` exposes `assemble_context()` and `close_session()` as free functions. Nothing prevents calling `close_session` twice or running tool calls before context is assembled. Used from `discord.rs` (assemble_context in system prompt) and `main.rs` (close_session after run).

**Target:** `Session<S: SessionState>` with states `Uninitialized`, `Ready`, `Running`, `Closed`. Only `Session<Ready>` can `start()` → `Running`; only `Running` can `execute_tool` and `close()` → `Closed`. Impossible states don't compile.

**Effort:** ~0.5 day on top of existing Sprint 1 boundary. **Impact:** Correctness for overnight autonomous runs.

---

## 6. `notify` crate for real-time file watching — **Not started**

**Current state:** Watch-style context uses git diff at session start (`context_assembly`). Between heartbeat rounds (e.g. 5 min) there is no live file awareness.

**Target:** `notify::recommended_watcher` + crossbeam channel; background task watches repo. `assemble_context()` drains the channel for "what changed since last run" instead of (or in addition to) git diff. Near-zero CPU when idle; instant awareness on save.

**Effort:** ~0.5 day. **Impact:** Makes `watch_file` real-time instead of batch.

---

## 7. `rusqlite` connection pooling (r2d2) — **Not started**

**Current state:** Each DB module (`task_db`, `tool_health_db`, `episode_db`, `state_db`, `schedule_db`, `memory_db`, `ask_jeff_db`) opens `Connection::open(&path)` per call. No pool; under concurrent tool execution (e.g. delegate batch, parallel workers) `SQLITE_BUSY` is likely.

**Target:** `r2d2-sqlite` (or equivalent) with WAL + `PRAGMA busy_timeout=5000`, `OnceLock<Pool<SqliteConnectionManager>>`, single `db()` accessor. Concurrent reads free; writes queue cleanly.

**Effort:** ~0.5 day. **Impact:** Required once Tower concurrency allows parallel tool execution.

---

## Meta: sequencing

Items 1–3 compound: proc macro generates boilerplate, inventory auto-registers, Tower wraps execution. Suggested order (see ROADMAP):

1. **Tower stack** — immediate reliability and cost/health in one place.
2. **tracing migration** — observability and introspect for free.
3. **Proc macro** — then **inventory** — fast-tool-creation pipeline.
4. **Typestate sessions** — then **connection pool** — then **notify** — polish that compounds over time.
