# Bulletproof the Chassis: Implementation Assessment and Hardening Strategy

This doc assesses how much of what we claim (blog, roadmap, README) is **actually implemented and reliable**, then proposes a prioritized strategy to harden the core so the chassis is bulletproof before adding more features.

---

## 1. Implementation Assessment

### 1.1 Claimed vs reality (by area)

| Claim / feature                                | Implemented? | Evidence                                                                        | Gaps / risks                                                                                                                                                           |
| ---------------------------------------------- | ------------ | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Rust core, &lt;20MB idle, sub-10ms startup** | ✅ Yes       | Single binary, no Node; no benchmark in repo                                    | **Unverified:** No automated memory/startup benchmark; “under 20MB” and “sub-10ms” are design targets, not CI-checked.                                                 |
| **Schema-validated tool boundaries**           | ✅ Yes       | Every tool has `input_schema()`; provider logs malformed tool JSON              | Malformed args fall back to `json!({})`; some tools may tolerate missing fields (e.g. optional content).                                                               |
| **CLI timeout (60s), output cap (2500)**       | ✅ Yes       | `cli_tool.rs`: `tokio::time::timeout`, truncation                               | Solid.                                                                                                                                                                 |
| **Allowlist / blocklist**                      | ✅ Yes       | First-token check in `allowed()`                                                | Solid.                                                                                                                                                                 |
| **SQLite + FTS5 memory**                       | ✅ Yes       | `memory_db.rs`: table, FTS5, migrate from JSON                                  | **Risk:** FTS5 `keyword_search` builds MATCH from `query.replace(' ', " OR ")` with no escaping; special chars (`"`, `:`, `-`, etc.) can break or alter FTS5 syntax.   |
| **RRF (keyword + semantic)**                   | ✅ Yes       | `memory_tool.rs`: `recall_for_context` merges FTS5 + cosine when both available | Depends on SQLite + embed path; one fragile `.unwrap()` in recall path (see below).                                                                                    |
| **In-process embeddings (fastembed)**          | ✅ Yes       | `embed_inprocess.rs`, feature `inprocess-embed`                                 | **CI:** Default build has no `inprocess-embed`; that code path is not tested in CI. Embed test is `#[cfg(feature = "inprocess-embed")]` and may skip if model missing. |
| **WASM wasm_calc**                             | ✅ Yes       | `wasm_runner.rs`, `wasm_calc_tool.rs`; wasmtime CLI, no FS/network              | **CI:** No wasmtime on runner; no WASM build or test in CI. If wasm path wrong, tool returns user-facing error (no panic).                                             |
| **Delegate (summarize, extract)**              | ✅ Yes       | `delegate_tool.rs`; worker provider, task types                                 | Unit tests for reject/require; no integration test with real API.                                                                                                      |
| **Tavily web_search**                          | ✅ Yes       | `tavily_tool.rs`; env-gated                                                     | No unit test (would need mock or key).                                                                                                                                 |
| **Heartbeat (heartbeat-learn.sh)**             | ✅ Yes       | Script runs agent in rounds; preflight, duration, interval                      | Depends on model + Tavily; no automated test in CI.                                                                                                                    |
| **Warm-the-ovens**                             | ✅ Yes       | `warm-the-ovens.sh` + Discord `ensure_ovens_warm()`                             | Bot waits up to 90s; script has its own timeout.                                                                                                                       |
| **Chump Menu**                                 | ✅ Yes       | SwiftUI app; start/stop 8000, 8001, embed, Chump, heartbeat                     | Separate build; not in rust-agent CI.                                                                                                                                  |
| **Audit log (chump.log)**                      | ✅ Yes       | `chump_log.rs`: append message, reply, CLI                                      | Solid.                                                                                                                                                                 |
| **Autonomy tiers**                             | ✅ Yes       | `run-autonomy-tests.sh`, tier file                                              | Requires model + optional Tavily; not run in CI.                                                                                                                       |

### 1.2 Test coverage (current)

| Component                        | Unit tests                                            | Integration / CI                                      |
| -------------------------------- | ----------------------------------------------------- | ----------------------------------------------------- |
| `calc_tool`                      | ✅ 3 tests (add, divide by zero, unknown op)          | ✅ `cargo test`                                       |
| `memory_db`                      | ✅ 2 tests (db_available, insert+load+keyword_search) | ✅ `cargo test` (uses temp dir)                       |
| `delegate_tool`                  | ✅ 2 tests (reject unknown task_type, require text)   | ✅ `cargo test` (no live API)                         |
| `embed_inprocess`                | ✅ 1 test (embed shape, skips if no model)            | Only when `--features inprocess-embed`; **not in CI** |
| `memory_tool`                    | ❌ None                                               | —                                                     |
| `cli_tool`                       | ❌ None                                               | —                                                     |
| `wasm_calc_tool` / `wasm_runner` | ❌ None                                               | No wasmtime in CI                                     |
| `tavily_tool`                    | ❌ None                                               | —                                                     |
| `local_openai`                   | ❌ None                                               | —                                                     |
| Discord handler                  | ❌ None                                               | —                                                     |

**CI (`.github/workflows/rust-agent.yml`):** `cargo build --release` → `cargo test` → `cargo clippy`. No feature flags, no wasmtime, no live server.

### 1.3 Panic and error-handling risks

- **memory_tool.rs:249** — `embed_server_url().unwrap()`. Context: we’re in `!use_inprocess_embed()` and we already ensured `has_embed` (so URL is `Some`). Logically safe but brittle; a refactor could make this panic. Prefer `if let Some(base) = embed_server_url()` or `.expect("embed url when not inprocess")`.
- **memory_db FTS5** — `keyword_search` uses `query.trim().replace(' ', " OR ")` and passes it to `MATCH ?1`. FTS5 has special characters (`"`, `:`, `-`, etc.). Unescaped user/model input can cause query errors or unexpected behavior. We should escape or quote the FTS5 query (e.g. wrap in double quotes and escape internal `"`).
- **calc_tool / delegate_tool tests** — Use `.unwrap()` in test code only; acceptable.
- **reqwest Client::build().unwrap_or_default()** — In memory_tool; if build fails we get default client. Prefer logging or propagating error if default is not acceptable.

### 1.4 Docs vs code

- **ROADMAP** — Says “summarize” for delegate; code has **summarize** and **extract**. ROADMAP “Current” for Phase 3 should mention extract.
- **Blog** — Matches current features; “sub-10ms” and “under 20MB” are not measured in CI (document as design targets or add a benchmark).

---

## 2. Bulletproof-the-Chassis Strategy

Goal: **Harden the core so that what we claim is true, testable, and fails safely.** Prioritize: (1) no panics in production paths, (2) security/safety (input validation, FTS5), (3) CI coverage for critical paths, (4) optional benchmarks.

### Phase A: Eliminate panic and input-safety risks (1–2 days)

1. **memory_tool recall path**
   - Replace `embed_server_url().unwrap()` with `if let Some(base) = embed_server_url()` (or equivalent) so the branch is impossible to trigger without a URL. Add a short comment so future refactors don’t reintroduce unwrap.

2. **memory_db FTS5 query safety**
   - In `keyword_search`, sanitize/escape the user query for FTS5 before building the MATCH expression. Options: (a) wrap the whole query in double quotes and escape internal `"` (per FTS5 docs), or (b) strip/allowlist characters and then quote. Add a unit test that runs `keyword_search` with a string containing `"`, `:`, or `-` and assert no crash and sensible (or empty) result.

3. **Optional: reqwest client in memory_tool**
   - Replace `Client::builder().build().unwrap_or_default()` with explicit handling: log a warning and fall back to keyword-only recall if client build fails, or propagate error. Prefer not to panic.

**Exit criteria:** No unwrap in production recall path; FTS5 query safe for arbitrary user input; tests for FTS5 with special chars.

### Phase B: Core unit tests (1–2 days)

4. **memory_tool**
   - Tests that don’t need embed server or DB: (a) `keyword_recall` with empty entries, with query, without query; (b) `recall_for_context` with no embed and JSON fallback (or mock file) returns keyword-only; (c) store then recall with JSON backend in temp dir. Avoid dependency on real embed server in CI.

5. **cli_tool**
   - (a) `allowed()` / blocklist: command in blocklist rejected; (b) allowlist empty => all allowed (or per your spec); allowlist non-empty => only listed executables allowed. (c) Optional: timeout and output cap (could use a slow/no-op command or mock).

6. **local_openai**
   - (a) Build a minimal `LocalOpenAIProvider` and call `complete()` with a small message list; use a mock HTTP server (e.g. wiremock or a tiny in-process server) that returns valid OpenAI-format JSON. Assert tool_calls and content are parsed. (b) Assert malformed tool JSON in the response is logged and mapped to empty object (no panic).

**Exit criteria:** New tests in CI; `cargo test` passes; memory_tool and cli_tool have at least the tests above.

### Phase C: CI and feature coverage (1 day)

7. **CI: inprocess-embed and optional wasm**
   - Add a CI job (or matrix entry) that builds and runs tests with `--features inprocess-embed`. If the embed model isn’t available on the runner, the existing embed test can skip (already returns Ok or skip). That way the feature compiles and the test runs when possible.
   - Optional: Job that installs wasmtime, builds `wasm/calculator.wasm`, and runs `cargo test` so wasm_calc path is exercised (can be separate workflow or manual).

8. **ROADMAP and blog**
   - Update ROADMAP Phase 3 “Current” to mention **extract** alongside summarize. In the blog (or README), add one line that “under 20MB” and “sub-10ms” are design targets unless you add a benchmark.

**Exit criteria:** CI runs with `inprocess-embed`; ROADMAP and (if desired) blog are accurate.

### Phase D: Observability and failure modes (optional, ~1 day)

9. **Structured logging**
   - Consider a single log line per tool call (tool name, duration, success/error) and per recall (keyword-only vs hybrid, count returned). Helps debug and verify behavior without changing contracts.

10. **Graceful degradation**
    - Ensure: (a) Embed server down → keyword-only recall (already there). (b) SQLite unavailable or corrupt → JSON fallback (already there). (c) Model server 5xx or connection error → user sees a clear “model unavailable” style message (check Discord handler and agent run path). Document these in TROUBLESHOOTING or CHUMP_SERVICE.

**Exit criteria:** Doc or code comments that describe degradation; no silent panics.

---

## 3. Priority Order and Checklist

| Priority | Item                                                        | Owner | Done |
| -------- | ----------------------------------------------------------- | ----- | ---- |
| P0       | memory_tool: remove embed_server_url().unwrap()             | —     | ☐    |
| P0       | memory_db: FTS5 query escaping + test with special chars    | —     | ☐    |
| P1       | memory_tool: unit tests (keyword recall, store/recall JSON) | —     | ☐    |
| P1       | cli_tool: unit tests (allow/block, allowlist empty)         | —     | ☐    |
| P1       | local_openai: mock-based parse test + malformed JSON        | —     | ☐    |
| P2       | CI: build and test with --features inprocess-embed          | —     | ☐    |
| P2       | ROADMAP: add extract to Phase 3 Current                     | —     | ☐    |
| P2       | Optional: reqwest client build fallback in memory_tool      | —     | ☐    |
| P3       | CI: wasmtime + wasm build + test (optional job)             | —     | ☐    |
| P3       | Doc: design targets (20MB, sub-10ms) or add benchmark       | —     | ☐    |
| P3       | Degradation and troubleshooting doc                         | —     | ☐    |

---

## 4. What “bulletproof” means after this

- **No panics** in the memory/recall path and no unsafe FTS5 query construction.
- **Critical paths tested:** memory (keyword + store/recall), CLI (allow/block), provider (parse + malformed JSON).
- **CI** runs default and inprocess-embed builds and tests; optional WASM in CI or docs.
- **Docs** match behavior (ROADMAP, design targets); degradation and troubleshooting are documented.

After Phase A–C, the chassis is in good shape to add more tools, more delegate task types, or speculative decoding without regressing safety or observability.
