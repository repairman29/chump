# Chump — Exhaustive Action Plan

**Goal:** Run out of things to code. Every task below is concrete, scoped, and independently shippable. Organized by phase so work can be parallelized across agents or dogfooded by Chump itself.

**How to use:** Pick any unchecked item. Each task has a file path, what to do, and a definition of done. Mark the checkbox when merged. Tasks within a phase are independent unless noted.

**Dogfooding note:** Tasks marked with `[DF]` are good candidates for Chump to execute on itself once the 14B model is running. Start with Phase 1 (human), then hand Phase 2+ to Chump as confidence grows.

---

## Phase 0: Beta Gate (ship before testers arrive)

These block sending the repo to anyone.

- [ ] **0.1** Update `scripts/setup-local.sh` to prefer `.env.minimal` over `.env.example`
  - File: `scripts/setup-local.sh`
  - Done: ✓ (completed in this session)

- [ ] **0.2** Add `.env.minimal` (10-line starter config)
  - File: `.env.minimal`
  - Done: ✓ (completed in this session)

- [ ] **0.3** Clean up README above-the-fold
  - File: `README.md`
  - Done: ✓ (completed in this session)

- [ ] **0.4** Add `BETA_TESTERS.md` one-pager
  - File: `BETA_TESTERS.md`
  - Done: ✓ (completed in this session)

- [ ] **0.5** Add friction report issue template
  - File: `.github/ISSUE_TEMPLATE/friction_report.md`
  - Done: ✓ (completed in this session)

- [ ] **0.6** Verify CI is green on main
  - Command: check GitHub Actions
  - Done when: latest commit on main has green CI badge

- [ ] **0.7** Run `./scripts/verify-external-golden-path.sh` on a clean clone
  - Command: `git clone https://github.com/repairman29/chump.git /tmp/chump-test && cd /tmp/chump-test && ./scripts/verify-external-golden-path.sh`
  - Done when: all checks pass, no errors

---

## Phase 1: Code Quality & Hardening

Reduce tech debt, eliminate panics in production paths, remove dead code. All items are independently mergeable. Good warm-up tasks for dogfooding.

### 1A: Unwrap/Expect Cleanup

Replace `unwrap()` and `expect()` with proper error handling in production (non-test) code paths. Each file is one PR.

- [ ] **1A.1** `src/tool_middleware.rs` — semaphore/lock `.expect()` calls (lines 221, 531-539) `[DF]`
  - Replace with `.map_err()` returning a `ToolError`
  - Done when: no `.expect()` on mutex/semaphore in non-test code

- [ ] **1A.2** `src/policy_override.rs` — lock `.expect()` calls (lines 23, 129) `[DF]`
  - Replace with `.map_err()` or `match`
  - Done when: no `.expect()` in non-test code

- [ ] **1A.3** `src/provider_cascade.rs` — `.lock().unwrap()` (lines 111, 127) `[DF]`
  - Replace with proper error propagation
  - Done when: no `.unwrap()` on mutex in non-test code

- [ ] **1A.4** `src/spawn_worker_tool.rs` — `.as_array().unwrap()` (line 364) `[DF]`
  - Replace with `.as_array().ok_or_else(|| ...)`
  - Done when: no `.unwrap()` on JSON access in non-test code

- [ ] **1A.5** `src/memory_tool.rs` — `.unwrap()` in `recall_for_context` path (line 772) `[DF]`
  - Check if this is actually in production or test; fix if production
  - Done when: verified test-only or replaced with `?`

- [ ] **1A.6** `src/local_openai.rs` — `.unwrap()` in token trimming logic (lines 800, 847, 851, 869) `[DF]`
  - Replace with proper error handling or `unwrap_or_default()`
  - Done when: no `.unwrap()` in non-test code

### 1B: Dead Code Cleanup

Remove `#[allow(dead_code)]` markers by either wiring up the function or deleting it. Each is one small PR.

- [ ] **1B.1** Audit all `#[allow(dead_code)]` in `src/` — create a spreadsheet of which to keep vs delete `[DF]`
  - Command: `grep -rn "allow(dead_code)" src/`
  - Files: tool_middleware.rs, session.rs, memory_tool.rs, web_server.rs, state_db.rs, cli_tool.rs, discord.rs, provider_quality.rs, cost_tracker.rs, local_openai.rs, chump_log.rs, task_db.rs, embed_inprocess.rs, tool_health_db.rs, schedule_db.rs, episode_db.rs, task_contract.rs, memory_db.rs
  - Done when: each function is categorized as "wire up", "delete", or "keep with justification"

- [ ] **1B.2** Delete functions confirmed as dead (no callers, no planned use) `[DF]`
  - Done when: `cargo clippy --workspace --all-targets -- -D warnings` passes with fewer `dead_code` allows

- [ ] **1B.3** Wire up functions that should be called (e.g., `discord.rs:577` public API) `[DF]`
  - Done when: function is called from at least one production code path or deleted

### 1C: Stub Completion

- [ ] **1C.1** `src/task_executor.rs` — SwarmExecutor: decide keep or remove
  - Lines 1-3, 120-133: stub logs and falls back to local
  - Decision: if cluster mode is not planned for beta, delete the stub and `CHUMP_CLUSTER_MODE` env var
  - If keeping: document as experimental in `docs/OPERATIONS.md`
  - Done when: no stub that silently does nothing

- [ ] **1C.2** `src/holographic_workspace.rs` — `module_awareness()` deprecated function (line 113)
  - Remove deprecated function or implement proper module vector alignment
  - Done when: no `#[deprecated]` markers on functions that are called

### 1D: Test Coverage Gaps

- [ ] **1D.1** Add e2e test for light context mode (`CHUMP_LIGHT_CONTEXT=1`) `[DF]`
  - File: `e2e/tests/daily-driver-api.spec.ts`
  - Test: health check + one chat turn with `CHUMP_LIGHT_CONTEXT=1`
  - Done when: test passes in CI

- [ ] **1D.2** Add e2e test for air-gap mode (`CHUMP_AIR_GAP_MODE=1`) `[DF]`
  - File: `e2e/tests/daily-driver-api.spec.ts`
  - Test: verify `web_search` and `read_url` tools are not registered
  - Done when: test passes in CI

- [ ] **1D.3** Add unit test for tool rate limiting behavior `[DF]`
  - File: `src/tool_middleware.rs`
  - Test: fire N+1 calls in window, verify Nth+1 is throttled
  - Done when: test passes

- [ ] **1D.4** Add unit test for circuit breaker recovery `[DF]`
  - File: `src/tool_middleware.rs`
  - Test: trip circuit, wait cooldown, verify recovery
  - Done when: test passes

---

## Phase 2: Test-Driven Editing (WS2 completion)

This is the single feature that moves Chump from "good" to "great." Each item builds on the previous.

- [ ] **2.1** Flip `test_aware_enabled()` default to ON when `CHUMP_REPO` is set
  - File: `src/test_aware.rs`
  - Change: `test_aware_enabled()` returns `true` when `repo_root_is_explicit()` unless `CHUMP_TEST_AWARE=0`
  - Done when: `CHUMP_TEST_AWARE` unset + `CHUMP_REPO` set → test-aware is on
  - Test: add unit test for default-on behavior

- [ ] **2.2** Rich failure feedback from test runs
  - File: `src/test_aware.rs`
  - Change: `check_regression()` returns structured error with:
    - Failing test names
    - Error output (capped at 2000 chars)
    - File region that was edited (10 lines before/after)
    - Attempt count and remaining retries
  - Done when: test failure returns actionable message, not just "tests failed"
  - Test: add test that triggers a regression and verifies message format

- [ ] **2.3** Agent loop retry injection on test regression
  - File: `src/agent_loop.rs` (tool results handling, ~lines 560-574)
  - Change: detect test regression marker in `ToolResult`, inject synthetic follow-up: "Tests regressed. Fix the failing tests. You have {N} attempts remaining."
  - Track retry count per file path. Max 3 retries.
  - Done when: agent auto-retries on test failure without user intervention
  - Test: mock a tool result with regression marker, verify retry injection

- [ ] **2.4** Verified commit gate
  - File: `src/git_tools.rs` (GitCommitTool)
  - Change: before `git commit`, run `cargo test --quiet`. Block if tests fail.
  - Add `force` param to bypass. Add `CHUMP_COMMIT_SKIP_TESTS` env var.
  - Log blocked commits via `chump_log::log_git_commit_blocked()`
  - Done when: `git_commit` tool refuses to commit with failing tests
  - Test: mock test failure, verify commit blocked

- [ ] **2.5** System prompt instruction for test-driven editing
  - File: `src/discord.rs` (system prompt assembly)
  - Change: when `test_aware_enabled()`, append 4-line instruction (~60 tokens)
  - Done when: system prompt includes test-driven instructions when repo is set

---

## Phase 3: Consciousness Decision

Run the A/B harness, get data, make the keep/park decision. This unblocks simplification or promotion.

- [ ] **3.1** Create no-op consciousness substrate
  - File: `src/consciousness_traits.rs` (or new `src/consciousness_noop.rs`)
  - Change: implement all consciousness trait methods as no-ops (return defaults)
  - Gate: `CHUMP_CONSCIOUSNESS_ENABLED=0` returns no-op substrate
  - Done when: consciousness can be cleanly disabled without code changes
  - Test: verify no-op substrate satisfies all trait bounds

- [ ] **3.2** Instrument decision metrics
  - Files: `src/tool_middleware.rs`, `src/agent_loop.rs`
  - Add counters: `consciousness_escalations`, `speculative_rollbacks`, `speculative_commits`, `blackboard_broadcasts`
  - Expose via `GET /api/health` consciousness_dashboard
  - Done when: counters increment during agent runs and show in health endpoint

- [ ] **3.3** Build A/B mini-harness
  - File: `scripts/consciousness-ab-mini.sh` (exists but needs population)
  - Define 20 coding tasks with known correct outcomes
  - Run each twice: consciousness ON vs OFF
  - Measure: completion, tool calls, latency, retries
  - Output: CSV + summary statistics
  - Done when: script runs end-to-end and produces comparison data

- [ ] **3.4** Run harness and log results
  - File: `docs/CONSCIOUSNESS_UTILITY_PASS.md` (append results)
  - Done when: results table populated with actual data
  - Decision: >5% completion improvement → keep ON by default; <5% → make opt-in; negative → remove from agent loop

---

## Phase 4: Latency & Performance

Build on the 52x speedup already achieved. Squeeze more out.

- [ ] **4.1** Add structured timing to every LLM request
  - File: `src/local_openai.rs`
  - Add: `prompt_construction_ms`, `time_to_first_token_ms`, `inference_ms`, `tool_execution_ms`
  - Log all four as structured tracing fields on every turn
  - Done when: `RUST_LOG=rust_agent=debug` shows all four timings per request

- [ ] **4.2** Measure latency before/after tool profile reduction
  - Command: run `scripts/latency-envelope-measure.sh` with `CHUMP_TOOL_PROFILE=core` vs `full`
  - Append results to `docs/LATENCY_ENVELOPE.md`
  - Done when: table shows measurable difference

- [ ] **4.3** Fast model routing for simple tasks
  - File: `src/provider_cascade.rs` or new `src/model_router.rs`
  - Add `CHUMP_FAST_MODEL` env var (e.g., `qwen2.5:7b`)
  - Route to fast model when: no tools needed, single tool call, follow-up in same conversation
  - Route to full model when: multi-file edits, test failures, planning
  - Heuristic: if previous turn used 0-1 tools and user message <100 tokens, use fast model
  - Done when: simple "what is 2+2" routes to fast model, "refactor this module" routes to full model
  - Test: verify routing decisions with mock messages

- [ ] **4.4** Ollama configuration documentation
  - File: `docs/PERFORMANCE.md`
  - Document tested values for: `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_PARALLEL`, `num_ctx` reduction
  - Done when: doc has a "recommended Ollama config for daily driver" section with copy-paste values

---

## Phase 5: Positioning & Proof

Hard evidence that Chump works and is worth using.

- [ ] **5.1** Benchmark suite vs Aider (20 tasks)
  - File: `scripts/benchmark-vs-aider.sh`
  - Define 20 coding tasks: 5 simple, 5 medium, 5 hard, 5 multi-file
  - Run each with Chump (core profile) and Aider (same Ollama model)
  - Measure: completion (binary), correctness (tests pass), tool calls, latency, tokens
  - Output: CSV + markdown summary table
  - Done when: script runs, produces comparison, results in `docs/BENCHMARKS.md`

- [ ] **5.2** Air-gap demo recording
  - File: `scripts/demo-air-gap.sh`
  - Disable all network (`CHUMP_AIR_GAP_MODE=1`)
  - Run Chump with local Ollama, complete a real coding task
  - Record with asciinema
  - Done when: `.cast` file exists and plays back a complete coding task offline

- [ ] **5.3** First-5-users kit
  - File: update `BETA_TESTERS.md` + `templates/pilot-invite-email.md`
  - Tighten golden path to 10 min (excluding compile + model download)
  - Create 3 "good first issue" labels on real GitHub issues
  - Done when: 3 issues labeled, invite email template has concrete instructions

- [ ] **5.4** One-command install exploration
  - File: `scripts/install.sh` or `Makefile`
  - Investigate: `curl -sSL ... | sh` installer that checks Rust, Ollama, clones, builds
  - Or: `brew tap repairman29/chump && brew install chump`
  - Done when: documented decision (do it or defer) with reasoning in `docs/PACKAGING_AND_NOTARIZATION.md`

---

## Phase 6: PWA & UX Polish

Make the web interface feel complete, not like a developer tool.

- [ ] **6.1** PWA onboarding wizard (first-visit experience)
  - File: `web/index.html`
  - On first visit (no `chump_pwa_onboarding_done` in localStorage): show 3-step overlay
    1. "Welcome to Chump" — what it is
    2. "Check your connection" — hit `/api/health`, show green/red
    3. "Try it" — pre-filled prompt "What can you do?"
  - Done when: new browser session shows wizard, wizard dismisses and doesn't return

- [ ] **6.2** Empty state improvements
  - File: `web/index.html`
  - When no messages: show helpful prompt suggestions (not blank screen)
  - When no tasks: show "Create your first task" hint
  - Done when: every empty panel has an action hint

- [ ] **6.3** Error state improvements
  - File: `web/index.html`
  - When inference fails: show "Model not responding — is Ollama running?" with retry button
  - When health check fails: show connection troubleshooting inline
  - Done when: all error states have user-friendly messages with actions

- [ ] **6.4** Response streaming indicator
  - File: `web/index.html`
  - Show typing indicator / token-by-token streaming during LLM response
  - Done when: user sees progressive output, not a blank wait then full response

- [ ] **6.5** Mobile PWA responsiveness pass
  - File: `web/index.html`
  - Test on iPhone Safari and Android Chrome
  - Fix any layout breaks, tap targets too small, overflow issues
  - Done when: PWA is usable on mobile without horizontal scrolling

---

## Phase 7: Documentation Consolidation

Reduce 146 docs to a navigable set. Kill overlap.

- [ ] **7.1** Merge `ROADMAP.md` + `ROADMAP_PRAGMATIC.md` + `ROADMAP_FULL.md` into one file `[DF]`
  - Keep ROADMAP.md as canonical; inline the pragmatic phase gates as section headers
  - Delete ROADMAP_PRAGMATIC.md and ROADMAP_FULL.md; update all references
  - Done when: one roadmap file, all links updated, no broken references

- [ ] **7.2** Merge `LATENCY_ENVELOPE.md` into `PERFORMANCE.md` `[DF]`
  - PERFORMANCE.md becomes the single performance reference
  - Done when: one file, all links updated

- [ ] **7.3** Merge `PRODUCT_REALITY_CHECK.md` into `PRODUCT_CRITIQUE.md` `[DF]`
  - Reality check becomes a section in the critique doc
  - Done when: one file, all links updated

- [ ] **7.4** Create `docs/INTERNAL.md` index for internal-only docs `[DF]`
  - Move fleet, consciousness, cascade, and research docs under a clear "internal" section in `docs/README.md`
  - Done when: `docs/README.md` has clear "For users" vs "For developers" vs "Internal" sections

- [ ] **7.5** Archive completed/obsolete docs `[DF]`
  - Move docs that describe completed work (no remaining TODOs) to `docs/archive/`
  - Done when: active docs/ has only files with open items or evergreen reference

- [ ] **7.6** Script index in `docs/SCRIPTS_REFERENCE.md` `[DF]`
  - Categorize all 181 scripts: "Setup", "Daily use", "Operations", "Development", "Internal"
  - Done when: every script has a one-line description and category

---

## Phase 8: Dogfooding Infrastructure

Set up Chump to work on itself.

- [x] **8.1** Create task queue for Chump to execute
  - File: `docs/DOGFOOD_TASKS.md`
  - 12 tasks across 4 batches (mechanical → reasoning), each with acceptance criteria
  - Done: seeded with unwrap cleanup, test coverage, doc updates, stub removal

- [x] **8.2** Create `scripts/dogfood-run.sh` — run Chump on its own repo
  - Sets `CHUMP_REPO` to self, `CHUMP_BRAIN_AUTOLOAD=self.md,rust-codebase-patterns.md`
  - Full tool profile, test-aware mode enabled
  - Logs to `logs/dogfood/<timestamp>.log`
  - Supports one-shot prompt or autonomy_once mode

- [x] **8.2b** Create `chump-brain/rust-codebase-patterns.md` — codebase knowledge for self-improvement
  - Covers: tool creation (5-step), error handling, DB access, async patterns, RAII, testing, module org
  - Includes 10 "things I must NOT do" rules
  - Autoloaded via `CHUMP_BRAIN_AUTOLOAD`

- [ ] **8.3** First dogfood run — execute T1.1 (replace .expect in policy_override.rs)
  - Command: `just dogfood "In src/policy_override.rs, replace all .expect() calls on mutex locks with .map_err. Run cargo test after."`
  - Done when: Chump makes the change, tests pass, result logged in `docs/DOGFOOD_LOG.md`

- [ ] **8.4** Dogfood feedback loop — 5 runs logged
  - After each run, review the diff and score PASS/PARTIAL/FAIL/REFUSED
  - Log in `docs/DOGFOOD_LOG.md`
  - Done when: 5 runs logged with notes on what worked and what didn't

- [ ] **8.5** Iterate on brain file based on dogfood results
  - If Chump makes pattern mistakes, add rules to `chump-brain/rust-codebase-patterns.md`
  - If Chump succeeds consistently, expand task complexity
  - Done when: brain file updated with at least 3 lessons learned from dogfood runs

---

## Phase 9: CI & Release

Harden the build and release pipeline.

- [ ] **9.1** Add macOS CI runner
  - File: `.github/workflows/ci.yml`
  - Add `macos-latest` job: `cargo build`, `cargo test`, `cargo clippy`
  - Done when: CI runs on both Linux and macOS

- [ ] **9.2** Add golden path timing to CI
  - File: `.github/workflows/ci.yml`
  - Run `scripts/verify-external-golden-path.sh` on every PR
  - Done when: golden path check is a CI gate

- [ ] **9.3** Release binary builds
  - File: `.github/workflows/release.yml` (new)
  - On tag push: build release binaries for macOS (aarch64, x86_64) and Linux (x86_64)
  - Upload as GitHub release artifacts
  - Done when: `v0.1.0` tag produces downloadable binaries

- [ ] **9.4** Docker image
  - Files: `docker/Dockerfile`, `docker/docker-compose.yml` (already exist)
  - Verify they work end-to-end: build, run, health check
  - Add to CI: build Docker image on every PR (don't push, just verify it builds)
  - Done when: `docker compose up` starts Chump + Ollama and `/api/health` returns OK

- [ ] **9.5** Version bumping
  - File: `Cargo.toml`
  - Establish semver policy: when to bump major/minor/patch
  - Add `scripts/bump-version.sh` that updates Cargo.toml + tags
  - Done when: script exists and produces a valid tagged commit

---

## Phase 10: Stretch Goals

Only after Phases 1-9 are complete. Nice-to-have features.

- [ ] **10.1** Watch mode: `chump --watch src/` — re-run on file changes
- [ ] **10.2** MCP server mode: expose Chump tools as an MCP server for other agents
- [ ] **10.3** Plugin system: load custom tools from `~/.chump/plugins/`
- [ ] **10.4** Web terminal: embedded terminal in PWA for running shell commands
- [ ] **10.5** Voice input: Web Speech API in PWA for voice-to-prompt
- [ ] **10.6** Export conversation as markdown/PDF from PWA
- [ ] **10.7** Multi-model comparison: run same prompt through 2 models, show side-by-side
- [ ] **10.8** Git diff viewer in PWA: show pending changes before commit
- [ ] **10.9** Token usage dashboard: track cumulative token usage per session/day
- [ ] **10.10** Keyboard shortcuts in PWA: Ctrl+Enter send, Ctrl+K command palette

---

## Task Count Summary

| Phase | Tasks | Priority | Dogfood-able |
|-------|-------|----------|-------------|
| 0: Beta Gate | 7 | NOW | No |
| 1: Code Quality | 16 | High | 12 of 16 |
| 2: Test-Driven Editing | 5 | High | No (needs human review) |
| 3: Consciousness Decision | 4 | Medium | No (needs judgment) |
| 4: Latency & Performance | 4 | Medium | Partially |
| 5: Positioning & Proof | 4 | Medium | No |
| 6: PWA & UX Polish | 5 | Medium | No (needs visual review) |
| 7: Doc Consolidation | 6 | Low | 6 of 6 |
| 8: Dogfood Infrastructure | 4 | Medium | Meta |
| 9: CI & Release | 5 | High | No |
| 10: Stretch Goals | 10 | Low | Varies |
| **Total** | **70** | | **~24 dogfood-able** |

---

## Execution Order (recommended)

```
Week 1: Phase 0 (beta gate) + Phase 1A (unwrap cleanup)
Week 2: Phase 2 (test-driven editing) + Phase 1B (dead code)
Week 3: Phase 9.1-9.2 (CI) + Phase 4 (latency)
Week 4: Phase 3 (consciousness A/B) + Phase 8 (dogfood setup)
Week 5: Phase 5 (benchmarks) + Phase 6 (PWA polish)
Week 6: Phase 7 (doc consolidation) + Phase 8.2-8.4 (dogfood runs)
Week 7+: Phase 9.3-9.5 (release) + Phase 10 (stretch)
```

After Week 4, Chump should be eating Phase 1 and Phase 7 tasks via dogfood runs. By Week 6, aim for Chump to handle routine code quality tasks autonomously with human review on PRs.
