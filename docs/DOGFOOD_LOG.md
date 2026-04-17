# Dogfood Run Log

## Run 1 — T1.1: Replace `.expect()` in `src/policy_override.rs`

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Model** | Local 7B (via Ollama) |
| **Task** | T1.1 — Replace `.expect()` on mutex locks in policy_override.rs |
| **Score** | **FAIL** |
| **Duration** | ~27s (1 model call) |

### What happened

The model emitted text-format tool calls — the parser fix from `442c121` successfully detected the pattern. However two problems:

1. **Two calls on one line**: The model put `call run_cli with {...}; call write_file with {...}` on a single line separated by `;`. The parser processes line-by-line, so it tried to parse the entire line as one call. The JSON extraction failed because `{...}; call write_file...` is not valid JSON.

2. **Hallucinated file content**: Instead of reading `policy_override.rs` first, the model fabricated entirely new file content (a generic mutex example, not the actual file). This would have destroyed the file if the tool had executed.

### Result

`tool_calls_count: 0` — no tools were dispatched. The model got one turn, failed to execute any tools, and the turn completed.

### Findings for improvement

- **P1**: Parser should split on `;` before matching, or handle multiple calls per line.
- **P2**: 7B model needs stronger system prompt guidance: "Always read a file before writing it."
- **P3**: Consider adding a `read_before_write` guardrail in tool middleware that rejects `write_file` calls for paths not previously read in the session.
- **P4**: The duplicate `"call "` prefix on lines 238 and 244 of `agent_loop.rs` should be cleaned up (harmless but confusing).

---

## Run 2 — T1.1 (retry): CLI panic in policy_override.rs

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 — Replace `.expect()` on mutex locks |
| **Score** | **FAIL** (crash) |
| **Duration** | <1s |

### What happened

CLI mode (`--chump`) panicked at `policy_override.rs:110`: `cannot access a task-local storage value without setting it first`. The `RELAX_TOOLS` task-local was only initialized in the web path (`relax_scope`), not in CLI mode.

### Fix applied

Changed `.with()` to `.try_with().unwrap_or(false)` in `session_relax_active_for_tool()` (commit `eafb5e4`).

---

## Run 3 — T1.1 (retry): Tool approval timeout

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 via web API |
| **Score** | **FAIL** (timeout) |
| **Duration** | ~27s |

### What happened

Via the web API, tools were dispatched (`run_cli`, `write_file`) but blocked on human approval. Nobody clicked "approve" in the PWA, so both timed out. This is correct web behavior but wrong for dogfood.

### Fix applied

Added `CHUMP_AUTO_APPROVE_TOOLS` and `CHUMP_AUTO_APPROVE_LOW_RISK=1` to `dogfood-run.sh` (commit `87be6f1`).

---

## Run 4 — T1.1 (retry): bare `tool_name {json}` not parsed

| Field | Value |
|-------|-------|
| **Date** | 2026-04-15 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 |
| **Score** | **FAIL** (parser gap) |
| **Duration** | ~20s |

### What happened

Model output `read_file {"path": "src/policy_override.rs"}` — bare tool name + space + JSON. Parser only handled `tool_name({json})` (parens) and prefix patterns. No match.

### Fix applied

Added bare `tool_name {json}` pattern to parser (commit `87be6f1`).

---

## Run 5 — T1.1 (retry): Tools dispatching!

| Field | Value |
|-------|-------|
| **Date** | 2026-04-15 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 |
| **Score** | **PARTIAL** |
| **Duration** | ~30s (3 model calls, 324 tokens) |

### What happened

The agent loop is working:
1. Model called `read_file` — **dispatched and executed successfully**
2. Model read the file contents
3. Model generated a diff attempting to replace `.expect()` with `.map_err()`
4. But the diff wasn't properly structured as a `patch_file` tool call — it was output as raw text

### Remaining issues

- Model generates diffs as text rather than calling `patch_file` with structured JSON input
- Only targeted one `.expect()` instance (repeated same diff twice)
- Didn't add `?` operator after `.map_err()`

### Assessment

First successful multi-turn tool use in dogfood! The infrastructure is working. The 7B model just needs better prompting to use `patch_file` with the right input schema.

---

## Run 6 — T1.1 (retry): 14B model, empty reply after tools

| Field | Value |
|-------|-------|
| **Date** | 2026-04-15 |
| **Model** | Qwen2.5-14B-Instruct-4bit |
| **Task** | T1.1 |
| **Score** | **FAIL** (empty reply) |
| **Duration** | ~45s (3 model calls, 484 tokens) |

### What happened

14B model dispatched `read_file` and `run_cli` but skipped `patch_file`. After the last tool result, model response was wrapped entirely in `<thinking>` tags — `strip_for_streaming_preview` produced empty text, failing the sanity check.

### Fix applied

When `tool_calls_count > 0` and display text is empty, synthesize "Executed N tool call(s)." (commit `6123117`).

---

## Run 7 — T1.1 (retry): 14B clean completion

| Field | Value |
|-------|-------|
| **Date** | 2026-04-15 |
| **Model** | Qwen2.5-14B-Instruct-4bit |
| **Task** | T1.1 |
| **Score** | **PARTIAL** |
| **Duration** | ~40s (3 model calls, 362 tokens) |

### What happened

Clean run: `read_file` → `run_cli` → "Executed 2 tool call(s)." No crash, no sanity failure. But the model skipped `patch_file` entirely — it read the file and ran tests without making the edit.

### Assessment

The agent loop is solid. The model understands "read then run tests" but doesn't bridge to "edit in between." This is a model quality issue — Qwen2.5-14B at 4-bit with limited context doesn't reliably produce structured `patch_file` calls.

### Next: try Qwen3.5-9B

Benchmarks show Qwen3.5-9B dramatically outperforms Qwen2.5-14B (91.5% IFEval, matches models 13x its size). Downloading via Ollama.

---

## Summary of infrastructure bugs found via dogfood

| # | Bug | Fix | Commit |
|---|-----|-----|--------|
| 1 | `task_local` panic in CLI mode | `try_with` | `eafb5e4` |
| 2 | Semicolon-separated tool calls | Split on `; call ` | `be84054` |
| 3 | Bare `tool_name {json}` syntax | New parser pattern | `87be6f1` |
| 4 | Missing `patch_file` example | Added to light prompt | `8366501` |
| 5 | Raw diff not dispatched | `rescue_raw_diff_as_patch()` | `8366501` |
| 6 | Narration retry after tool use | Skip when `tool_calls_count > 0` | `30afd9e` |
| 7 | Empty reply after successful tools | Synthesize fallback | `6123117` |

---

## T1.1 stays open — model matrix until pass

Early runs (above) used an earlier T1.1 wording. **Current** canonical prompt + verify are in [DOGFOOD_TASKS.md](DOGFOOD_TASKS.md) **T1.1** and [DOGFOOD_T1_1_MODEL_PROBE.md](DOGFOOD_T1_1_MODEL_PROBE.md).

**Per model:** `just dogfood-t1-1-probe <tag>` or `OPENAI_MODEL=<tag> ./scripts/dogfood-t1-1-probe.sh`, then append a new **Run** here and inspect `logs/dogfood/t1.1-model-probes.jsonl`. Do **not** start T1.2 until the probe exits **0**.

---

## Run — Full queue (Cursor executor): T1.1–T4.2 — 2026-04-09

| Field | Value |
|-------|-------|
| **Executor** | Cursor (direct code + `cargo test --bin chump`), not `dogfood-run.sh` |
| **Score** | **PASS** (all verify-style checks + full bin tests green) |

### Completed

- **T1.1** — `policy_override.rs`: poison-safe `SESSION_OVERRIDES.lock().unwrap_or_else(|e| e.into_inner())`.
- **T1.2** — `provider_cascade.rs`: same pattern for `minute_start` / `day_start` mutexes (grep `lock().unwrap()` clean).
- **T1.3** — `spawn_worker_tool.rs` test: `let Some(required) = …as_array() else { panic!(…) }` (only JSON unwrap was in tests).
- **T1.4** — `CHUMP_BRAIN_AUTOLOAD` already in `.env.example`; **T3.1** added row in `docs/OPERATIONS.md`.
- **T1.5** — `CHUMP_TOOL_PROFILE` documented in `.env.example`; **`chump_tool_profile()`** + defaults test in `env_flags.rs`.
- **T2.1** — existing `rate_limit_*` tests satisfy `cargo test --bin chump rate_limit`.
- **T2.2** — new `circuit_opens_then_recovers_after_cooldown` in `tool_middleware.rs`.
- **T2.3** — `env_flags_defaults_light_air_gap_tool_profile` (+ `ChumpToolProfile` enum).
- **T3.2** — Phase 8 intro links `docs/DOGFOOD_TASKS.md`; 8.1/8.2 already checked.
- **T4.1** — `SwarmExecutor`: `tracing::warn!` explicit stub message (keeps `[SWARM ROUTER]` substring for vector7 logs).
- **T4.2** — Removed `module_awareness` + unused `module_vectors` / `module_vector` in `holographic_workspace.rs`; doc touch `RETRIEVAL_EVAL_HARNESS.md`; **ACTION_PLAN** 1C.2 marked done.

### Fix during run

- **E2E / consciousness:** `assemble_context` skipped consciousness when **`CHUMP_LIGHT_CONTEXT`** leaked from the outer environment. **`setup_test_env`** (e2e) and **`setup_test_db`** (consciousness tests) now **`remove_var("CHUMP_LIGHT_CONTEXT")`** so suites are deterministic.

---

## Run — T1.1 end-to-end (dogfood-run.sh) — 2026-04-15/16

| Field | Value |
|-------|-------|
| **Executor** | `./scripts/dogfood-run.sh` against the built `target/release/chump` binary |
| **Models tested** | `qwen2.5:7b` via Ollama, `qwen3:8b` via Ollama (registered from HF GGUF), `Qwen3.5-9B-OptiQ-4bit` via vLLM-MLX |
| **Score** | **PASS on `qwen2.5:7b`** (run `20260415-140714`, exit 0, 3 model requests, 7770 in / 192 out tokens). **Blocked on `qwen3:8b`** — upstream Ollama 0.20.7 segfault under load on 24GB M4. |

### What T1.1 proved end-to-end

- `read_file` → `patch_file` → coherent response all executed without crash.
- New circuit breaker (`735b8fb`, `CHUMP_MAX_CONSECUTIVE_TOOL_FAILS`) short-circuits after 3 consecutive all-failed tool batches instead of burning all 25 iterations.
- `<think>` stripping (`f35918f`) prevents the Qwen3 reasoning accumulation that regressed the loop to 25 iterations before the fix.
- Patch parser `catch_unwind` (`01de3b6`) + `spawn_blocking` isolation (`f35918f`) keep a panic in the upstream `patch` crate from corrupting the tokio HTTP client.

### Bugs fixed during this run (9 commits on main)

| Commit | Fix |
|--------|-----|
| `6b92cfc` | `CHUMP_TOOL_TIMEOUT_SECS` env override + `patch_file` in `LIGHT_CHAT_TOOL_KEYS` |
| `01de3b6` | `patch` crate panic guarded with `catch_unwind` + default `num_ctx` 4096 → 8192 |
| `f35918f` | Qwen3 `<think>...</think>` strip + `spawn_blocking` patch isolation + `/no_think` CLI inject |
| `735b8fb` | Light-profile coverage test + fail-storm circuit breaker (`CHUMP_MAX_CONSECUTIVE_TOOL_FAILS`) |
| `0148eb7` | `dogfood-run.sh` env preservation + `gh_pr_list_comments` (closes Gap 3.3) + patch panic hook + `num_ctx` overflow warning |
| `1e3d7e5` | Deeper action verification (postconditions for write_file / patch_file / git_commit / git_push) |
| `71d2147` | Memory curation: confidence decay + exact-content dedupe |
| `cf22f3f` | Retrieval reranking (`rerank_memories` + `keyword_search_reranked`) + eval seeds 5 → 52 + types.rs coverage |

### Blocker: Ollama 0.20.7 segfault on 24GB M4

Observed across runs: Ollama responds HTTP 500 to `/v1/chat/completions` after ~13s of inference, then auto-restarts (visible in `/opt/homebrew/var/log/ollama.log` as repeated `"Listening on 127.0.0.1:11434"`). Not a Chump bug — the server dies while holding the connection. Workarounds: use `qwen2.5:7b` (lighter memory footprint), run with `CHUMP_BRAIN_AUTOLOAD=` empty, and avoid concurrent cargo builds. See `docs/DOGFOOD_RELIABILITY_GAPS.md`.

### Model landscape (current)

| Model | Path | T1.1 status |
|-------|------|-------------|
| `qwen2.5:7b` | Ollama | **Pass** (2026-04-15 run `20260415-140714`) |
| `qwen2.5:14b` | Ollama | Partial — RAM pressure under concurrent cargo; Ollama evicts mid-run |
| `qwen3:8b` (Q4_K_M) | Ollama | Blocked — upstream Ollama 0.20.7 segfault |
| `Qwen3.5-9B-OptiQ-4bit` | vLLM-MLX | Correct unified diffs, but vLLM-MLX segfaults under sustained load |
| `Qwen3-14B-4bit` | vLLM-MLX | Too slow (~0.5 tok/s), triggers tool timeouts |

### Session tests before → after

Test suite grew from **692 → 755 passing** across the 9 commits (+63 tests) — expanded eval seed cases (5 → 52), circuit-breaker unit tests, reranker tests, tool-profile coverage guards, `<think>` strip tests, Qwen3 chat-template integration.
