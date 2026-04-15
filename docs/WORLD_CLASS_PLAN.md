# Chump — World-Class Execution Plan

## Current Measurements

| Metric | Value |
|--------|-------|
| Registered tools | 54 |
| System prompt (no brain) | ~9,137 tokens |
| System prompt (with brain) | ~10,622 tokens |
| Tool routing table alone | 3,957 tokens (43% of base prompt) |
| Tool schemas (tools array) | ~16-20 KB (est. 4,000-5,000 tokens) |
| **Total context before user speaks** | **~14,000-16,000 tokens** |
| Warm response latency (14B Ollama) | ~62 seconds |
| Test-aware editing | Exists but off by default (`CHUMP_TEST_AWARE=1`) |
| Auto edit→test→retry | Does not exist |
| Consciousness A/B testable | Partially (context injection only, internal state always runs) |

---

## Workstream 1: Tool Surface Reduction

**Goal:** Cut system prompt by 40%+ and improve model tool selection accuracy.

### 1.1 — Create Tool Profiles

**File:** `src/tool_inventory.rs`

Define three profiles:

```
core        — 10 tools, default for all interactive use
coding      — 18 tools, when CHUMP_REPO is set
full        — 54 tools, opt-in for autonomy/fleet/advanced
```

**Core profile (10 tools):**
| Tool | Why |
|------|-----|
| read_file | Read files |
| write_file | Create/overwrite files |
| patch_file | Surgical edits (diff-based) |
| list_dir | Directory listing |
| run_cli | Shell commands (replaces 12+ git/gh/cargo tools) |
| run_test | Run test suites |
| memory_brain | Store/recall long-term facts |
| task | Create/query/complete tasks |
| web_search | Research (when TAVILY_API_KEY set) |
| read_url | Fetch web content |

**What gets cut from core:**
- `git_commit`, `git_push`, `git_stash`, `git_revert`, `cleanup_branches`, `merge_subtask` — model knows git CLI natively, use `run_cli`
- `cargo` — use `run_cli`
- `gh_create_branch`, `gh_create_pr`, `gh_get_issue`, `gh_list_issues`, `gh_list_my_prs`, `gh_pr_checks`, `gh_pr_comment`, `gh_pr_view_comments` — use `run_cli` with `gh` CLI
- `github_repo_read`, `github_repo_list`, `github_clone_or_pull` — use `run_cli`
- `calculator`, `wasm_calc`, `wasm_text` — model does math natively, or use `run_cli`
- `introspect`, `toolkit_status`, `ego`, `episode`, `schedule` — internal, not needed for interactive coding
- `notify`, `ask_jeff`, `message_peer` — fleet/discord only
- `codebase_digest`, `diff_review`, `battle_qa` — specialized, not core
- `delegate`, `spawn_worker`, `decompose_task`, `task_planner` — autonomy only
- `adb`, `screen_vision`, `sandbox_run` — specialized hardware
- `onboard_repo`, `set_working_repo`, `repo_authorize`, `repo_deauthorize` — setup, not runtime

**Coding profile adds:** `diff_review`, `run_test` (enhanced), `codebase_digest`

**Full profile adds:** Everything else

**Implementation:**
- [x] Add `CHUMP_TOOL_PROFILE` env var (`core`, `coding`, `full`; default `core`) — `env_flags.rs`
- [x] Modify `tool_inventory.rs` `register_from_inventory()` to filter by profile
- [x] Modify `tool_routing.rs` to generate routing table only for active profile — `routing_table_for_profile()`, `routing_table_core()`
- [x] Default `core` when `--web` or `--chump`; default `full` when `--autonomy-once` — `main.rs`

### 1.2 — Compress the Routing Table

**File:** `src/tool_routing.rs` (3,957 tokens — 43% of base prompt)

The routing table is a prose document telling the model when to use each tool. With 10 core tools, this shrinks to ~800 tokens.

- [x] Generate routing table dynamically from active profile — `routing_table_for_profile()`
- [x] Strip CLI detection fallbacks for tools not in active profile — core table is hand-crafted compact
- [x] Cap routing table at 1,000 tokens for core profile — core table is ~800 tokens

### 1.3 — Lazy Context Loading

**File:** `src/context_assembly.rs`

Don't inject everything on every turn.

- [ ] Portfolio/playbook: only inject on first turn or when task tool is called
- [ ] COS weekly snapshot: only inject in autonomy mode
- [ ] Brain autoload: already has turn cooldown (good), verify it's working
- [ ] Consciousness metrics: only inject when `CHUMP_TOOL_PROFILE=full`

### 1.4 — Measure and Log

- [x] Add `tracing::info!` with `approx_total_tokens`, `system_prompt_tokens`, `tool_count` to `local_openai.rs` before API call
- [x] Log both to structured output so we can track over time — `llm_request_budget` span

**Expected result:** Core profile system prompt drops from ~14,000-16,000 to ~6,000-8,000 tokens. Model selects correct tool on first try more often. Latency improves proportionally to token reduction.

---

## Workstream 2: Test-Driven Feedback Loop

**Goal:** When Chump edits code, it automatically verifies the edit and retries on failure. This is the single feature that moves Chump from "good" to "great."

### 2.1 — Enable Test-Aware by Default

**File:** `src/repo_tools.rs`, `src/test_aware.rs`

Currently gated behind `CHUMP_TEST_AWARE=1`. This should be the default.

- [ ] Change `test_aware_enabled()` to return `true` unless `CHUMP_TEST_AWARE=0`
- [ ] Ensure `capture_baseline()` is fast (timeout 30s, not full suite on large projects)
- [ ] Add framework auto-detection: look for `Cargo.toml`, `package.json`, `pyproject.toml` to pick runner
- [ ] Cache baseline results for 60 seconds to avoid re-running between rapid edits

### 2.2 — Rich Failure Feedback

**File:** `src/test_aware.rs`, `src/run_test_tool.rs`

When tests fail after an edit, the model needs enough context to fix it.

Current: returns "Tests failed: test_name_1, test_name_2"
Needed: returns failing test names + error output + relevant file excerpt

- [ ] Capture full stderr/stdout from test run (cap at 2000 chars)
- [ ] Extract actual error messages (panic message, assertion failure, compiler error)
- [ ] Include the file region that was just edited (10 lines before/after the change)
- [ ] Format as a structured error the model can act on:
  ```
  Edit caused 2 new test failures:
  
  FAIL: test_parse_config
    assertion failed: expected Some("value"), got None
    at src/config.rs:42
  
  FAIL: test_load_defaults  
    thread panicked at 'index out of bounds'
    at src/config.rs:67
  
  Your edit was at src/config.rs lines 35-50.
  Current file content (lines 30-70):
  [file excerpt]
  
  Fix the issues and call patch_file again.
  ```

### 2.3 — Agent Loop Retry Injection

**File:** `src/agent_loop.rs` (lines 560-574, tool results handling)

When a tool returns a test regression error, inject a follow-up system message that tells the model to fix and retry. Don't wait for the model to figure it out.

- [ ] Detect `ToolResult` containing test regression marker (add a structured field or prefix)
- [ ] On detection, append a synthetic assistant instruction: "Tests regressed. Fix the failing tests and re-apply your edit. You have {remaining} attempts."
- [ ] Track retry count per edit target (file path). Max 3 retries, then surface to user.
- [ ] On 3rd failure, auto-stash changes and report what happened

### 2.4 — Verified Commit Gate

**File:** `src/git_tools.rs` (GitCommitTool)

Never commit code that breaks tests.

- [ ] Before `git commit`, run `run_test` on the project
- [ ] If tests fail, block the commit and return: "Cannot commit: N tests failing. Fix them first."
- [ ] Add `--force` param to bypass (for intentional test changes)
- [ ] `diff_review` already runs before commit — keep it, add test check alongside
- [ ] Log all blocked commits to `chump.log`

### 2.5 — System Prompt Addition

Add to core system prompt (only when `CHUMP_REPO` is set):

```
When you edit code:
1. Make the smallest change that solves the problem
2. If tests fail after your edit, read the error and fix immediately
3. Never commit code with failing tests unless explicitly asked
4. If you can't fix a test failure in 3 attempts, stop and explain the problem
```

This costs ~60 tokens but dramatically improves edit behavior.

---

## Workstream 3: Consciousness A/B Framework

**Goal:** Determine if consciousness measurably improves task completion. Keep it or park it based on data.

### 3.1 — No-Op Substrate

**File:** `src/consciousness_traits.rs`

Create a no-op implementation that satisfies all trait interfaces but records nothing.

- [ ] Add `ConsciousnessSubstrate::noop()` that returns default/empty values for all queries
- [ ] Modify `substrate()` to return noop when `CHUMP_CONSCIOUSNESS_ENABLED=0`
- [ ] This cleanly disables: surprise tracking, belief updates, neuromod, blackboard posts, speculative evaluation
- [ ] Speculative execution in agent_loop should check `consciousness_enabled()` before forking

### 3.2 — Add Decision Metrics

**File:** `src/tool_middleware.rs`, `src/agent_loop.rs`

Instrument the places where consciousness currently influences behavior.

- [ ] Counter: `consciousness_escalations` — times `belief.should_escalate()` returned true
- [ ] Counter: `speculative_rollbacks` — times speculative batch was rolled back
- [ ] Counter: `speculative_commits` — times batch was committed
- [ ] Gauge: `task_uncertainty_at_turn_start` and `task_uncertainty_at_turn_end`
- [ ] Counter: `blackboard_broadcasts` — posts exceeding salience threshold
- [ ] Expose all via `/api/health` consciousness_dashboard (already partially there)

### 3.3 — A/B Harness

**New file:** `src/ab_harness.rs` (or script in `scripts/`)

- [ ] Define a task set: 50 well-scoped coding tasks with known correct outcomes
- [ ] Run each task twice: once with consciousness on, once off
- [ ] Measure per task:
  - Completion: did it succeed? (binary)
  - Tool calls: how many tool invocations?
  - Latency: total wall time
  - Retries: how many failed tool calls?
  - Token usage: total input + output tokens
- [ ] Output CSV for analysis
- [ ] Statistical test: paired t-test or Wilcoxon signed-rank on completion rate and tool efficiency

### 3.4 — Decision Point

After running the harness:

- **If consciousness improves completion rate by >5% or reduces tool calls by >10%:** Keep it on by default. Write it up as a differentiator.
- **If neutral (<5% difference):** Make it opt-in. Remove from default code paths. Reclaim latency.
- **If negative:** Remove it from the agent loop entirely. Keep the code as a research module.

---

## Workstream 4: Latency Pipeline

**Goal:** Reduce warm response from 62s to under 30s for simple queries, under 60s for tool-using turns.

### 4.1 — Measure the Breakdown

Before optimizing, know where time goes.

- [ ] Add timing to `local_openai.rs`:
  - `prompt_construction_ms`: time to build the messages/tools payload
  - `time_to_first_token_ms`: from request send to first SSE chunk
  - `inference_ms`: total model response time
  - `tool_execution_ms`: per tool (already partially logged)
- [ ] Log all four to structured tracing on every turn
- [ ] Identify: is 62s in inference? In prompt serialization? In Ollama overhead?

### 4.2 — System Prompt Reduction (Cross-reference WS1)

Workstream 1 directly reduces prompt tokens. Fewer tokens = faster inference.

- [ ] Measure latency before and after tool profile reduction
- [ ] Target: 30-40% token reduction → expect 20-30% latency improvement

### 4.3 — Model Routing

**File:** `src/provider_cascade.rs`

Use smaller models for simple tasks.

- [ ] Add `CHUMP_FAST_MODEL` env var (e.g., `qwen2.5:7b`)
- [ ] Route to fast model when:
  - No tools needed (pure chat)
  - Single tool call (simple read/list)
  - Follow-up questions in same conversation
- [ ] Route to full model (14B) when:
  - Multi-file edits
  - Test failures (need reasoning)
  - Planning/decomposition
- [ ] Heuristic: if previous turn used 0-1 tools and user message is <100 tokens, use fast model

### 4.4 — Ollama Configuration

- [ ] Document and test `OLLAMA_KEEP_ALIVE` (default `-1` = forever, vs `5m` default)
- [ ] Test `OLLAMA_NUM_PARALLEL=1` for single-user (avoids scheduling overhead)
- [ ] Test `num_ctx` reduction: 8192 for core profile (vs 32768 default) — directly reduces KV cache
- [ ] Test speculative decoding if Ollama supports it with your model pair

---

## Workstream 5: Positioning and Proof

**Goal:** Make Chump's unique value visible and provable.

### 5.1 — Benchmark Suite

**New file:** `scripts/benchmark-vs-aider.sh` or similar

Compare Chump vs Aider on the same local model (Qwen 14B via Ollama).

- [ ] Define 20 coding tasks across difficulty levels:
  - 5 simple: "add a function that does X"
  - 5 medium: "refactor this module to use pattern Y"  
  - 5 hard: "fix this bug given the stack trace"
  - 5 multi-file: "add feature X touching 3+ files"
- [ ] Run each with Chump (core profile) and Aider
- [ ] Measure: completion, correctness (tests pass), tool calls, latency, tokens
- [ ] If Chump wins on scaffolding (fewer tool calls, better error recovery): lead with that
- [ ] If Aider wins: analyze why and fix the gap

### 5.2 — Air-Gap Demo

- [ ] Script that disables all network (`CHUMP_AIR_GAP_MODE=1`), runs Chump with local Ollama, completes a real coding task
- [ ] Record as asciinema/terminal capture
- [ ] This is the hero demo. Nobody else can do this.

### 5.3 — One-Line Positioning

Update root README.md with:

```
# Chump

Self-hosted AI coding agent with persistent memory and autonomous task execution.
Runs entirely on your hardware. Your keys, your data, your machine.
```

Replace the current description with this. Everything else goes in docs.

### 5.4 — First-5-Users Kit

- [ ] 10-minute golden path (already started in EXTERNAL_GOLDEN_PATH.md — tighten to 10 min)
- [ ] GitHub issue template for friction reports
- [ ] 3 "good first issue" labels on real issues
- [ ] One-command install: `curl -sSL https://chump.dev/install | sh` (or brew tap)

---

## Execution Sequence

| Week | Workstream | Deliverable |
|------|-----------|-------------|
| 1 | WS1: Tool profiles | `CHUMP_TOOL_PROFILE=core` shipping, 10 tools, routing table compressed |
| 1 | WS4.1: Latency measurement | Structured timing on every turn, baseline numbers |
| 2 | WS2.1-2.2: Test-aware default + rich feedback | Test-aware on by default, rich error messages on failure |
| 2 | WS4.2-4.3: Prompt reduction + model routing | Measure latency delta, implement fast model routing |
| 3 | WS2.3-2.4: Retry injection + verified commit | Agent auto-retries on test failure, commits blocked on failing tests |
| 3 | WS3.1-3.2: No-op substrate + metrics | Clean consciousness toggle, decision metrics instrumented |
| 4 | WS3.3-3.4: A/B harness + decision | Run 100 tasks, make the keep/park decision |
| 4 | WS5.1-5.2: Benchmarks + air-gap demo | Hard numbers vs Aider, air-gap recording |
| 5 | WS5.3-5.4: Positioning + first-5 kit | README rewrite, install script, issue templates |
| 5 | Stabilize | Fix everything that broke during weeks 1-4 |

---

## Success Criteria

After 5 weeks:

| Metric | Before | Target |
|--------|--------|--------|
| Tools in default prompt | 54 | 10 |
| System prompt tokens | ~14,000-16,000 | ~6,000-8,000 |
| Warm response (simple query) | 62s | <30s |
| Auto-retry on test failure | No | Yes, up to 3 attempts |
| Commit with failing tests | Allowed | Blocked by default |
| Consciousness impact known | No | Yes, with data |
| Benchmark vs Aider | None | 20 tasks, published |
| External users completed golden path | 0 | 5 |
