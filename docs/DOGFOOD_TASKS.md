# Dogfood Task Queue

Tasks for Chump to execute on its own codebase. Ordered easiest → hardest. Each task has clear acceptance criteria so Chump can verify its own work.

**How to run:** `just dogfood "paste the task description here"` or create as a Chump task via the PWA/CLI and use `just dogfood-auto`.

**Rules:**
- One task per run. Don't chain.
- Always run `cargo test --bin chump` after changes.
- Never push — leave changes on a branch for human review.
- If stuck after 3 attempts, stop and log what happened.

---

## Batch 1: Mechanical Cleanup (safe, no judgment needed)

### T1.1 — Replace `.expect()` in `src/policy_override.rs`
**Prompt:** "In src/policy_override.rs, replace all `.expect()` calls on mutex locks with `.map_err(|_| anyhow!(\"lock poisoned\"))?`. There are 2 instances. Run cargo test after."
**Verify:** `grep -c 'expect' src/policy_override.rs` returns 0 for non-test code. Tests pass.

### T1.2 — Replace `.unwrap()` in `src/provider_cascade.rs` mutex locks
**Prompt:** "In src/provider_cascade.rs, find `.lock().unwrap()` calls (lines ~111 and ~127) and replace with `.lock().map_err(|_| anyhow!(\"cascade lock poisoned\"))?`. Run cargo test after."
**Verify:** `grep -n 'lock().unwrap()' src/provider_cascade.rs` returns nothing. Tests pass.

### T1.3 — Replace `.as_array().unwrap()` in `src/spawn_worker_tool.rs`
**Prompt:** "In src/spawn_worker_tool.rs around line 364, replace `.as_array().unwrap()` with `.as_array().ok_or_else(|| anyhow!(\"expected JSON array\"))?`. Run cargo test after."
**Verify:** No `.unwrap()` on JSON access in non-test code. Tests pass.

### T1.4 — Add missing env var to `.env.example`
**Prompt:** "Add CHUMP_BRAIN_AUTOLOAD to the .env.example file with a comment explaining it. Place it near the other brain-related settings. Example value: self.md,rust-codebase-patterns.md. Run cargo check after."
**Verify:** `grep CHUMP_BRAIN_AUTOLOAD .env.example` returns a documented entry.

### T1.5 — Document `CHUMP_TOOL_PROFILE` in `.env.example`
**Prompt:** "Verify that CHUMP_TOOL_PROFILE is documented in .env.example. If not, add it with values core/coding/full, default core, and a brief description of each profile. Place it near the tool-related settings."
**Verify:** `grep CHUMP_TOOL_PROFILE .env.example` returns a documented entry.

---

## Batch 2: Test Coverage (needs to understand test patterns)

### T2.1 — Add test for tool rate limiting
**Prompt:** "In src/tool_middleware.rs, add a test that verifies the rate limiting behavior. Create a test that calls a rate-limited tool more times than the limit allows within the time window, and verify the excess calls are rejected. Follow the existing test patterns in that file."
**Verify:** `cargo test --bin chump rate_limit` passes.

### T2.2 — Add test for circuit breaker recovery
**Prompt:** "In src/tool_middleware.rs, add a test that verifies circuit breaker recovery. Trip the circuit breaker by recording enough failures, verify calls are rejected, then advance time past the cooldown and verify calls succeed again. Follow existing test patterns."
**Verify:** `cargo test --bin chump circuit` passes.

### T2.3 — Add test for env_flags defaults
**Prompt:** "In src/env_flags.rs, add tests that verify the default values of key functions when no env vars are set: chump_light_context() should return false, air_gap_mode() should return false, tool profile should default to core. Clean up any env vars you set during tests."
**Verify:** `cargo test --bin chump env_flags` passes.

---

## Batch 3: Documentation (needs to read and write coherently)

### T3.1 — Add CHUMP_BRAIN_AUTOLOAD to docs/OPERATIONS.md
**Prompt:** "Read docs/OPERATIONS.md. Find the environment variables section. Add CHUMP_BRAIN_AUTOLOAD with a description of what it does (comma-separated brain-relative file paths auto-injected into agent context every turn), when to use it (small models that skip memory_brain tool calls), and the recommended default for dogfooding (self.md,rust-codebase-patterns.md)."
**Verify:** `grep BRAIN_AUTOLOAD docs/OPERATIONS.md` returns the new entry.

### T3.2 — Add dogfood section to docs/ACTION_PLAN.md
**Prompt:** "Read docs/ACTION_PLAN.md Phase 8. Update the dogfood tasks section to reference docs/DOGFOOD_TASKS.md as the task queue. Mark item 8.1 as complete (task queue exists) and 8.2 as complete (dogfood-run.sh exists)."
**Verify:** Phase 8 items 8.1 and 8.2 are checked off.

---

## Batch 4: Code Improvements (needs reasoning)

### T4.1 — Make SwarmExecutor decision explicit
**Prompt:** "Read src/task_executor.rs. The SwarmExecutor is a stub that falls back to local execution. Either: (a) remove the stub entirely and remove CHUMP_CLUSTER_MODE, or (b) add a tracing::warn! that explicitly says 'SwarmExecutor is a stub, falling back to local'. Option (a) preferred if nothing references CHUMP_CLUSTER_MODE besides this file. Run cargo test after."
**Verify:** No silent stubs. Tests pass.

### T4.2 — Remove deprecated `module_awareness()` function
**Prompt:** "Read src/holographic_workspace.rs. The function `module_awareness()` is marked as deprecated (line ~113). Check if anything calls it. If nothing calls it, remove the function and its tests. If something calls it, leave it but add a TODO comment explaining what needs to change. Run cargo test after."
**Verify:** No `#[deprecated]` in holographic_workspace.rs, or a clear TODO. Tests pass.

---

## Scoring

After each dogfood run, rate the result:

| Score | Meaning |
|-------|---------|
| **PASS** | Task completed correctly, tests pass, code fits patterns |
| **PARTIAL** | Made progress but needed human fixup |
| **FAIL** | Got stuck, broke tests, or made changes that don't fit codebase patterns |
| **REFUSED** | Correctly identified it couldn't complete the task and stopped |

Track results in `docs/DOGFOOD_LOG.md`.
