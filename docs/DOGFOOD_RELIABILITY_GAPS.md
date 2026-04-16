# Dogfood reliability gaps

**Purpose:** Single source of truth for bugs and infrastructure gaps surfaced by
running Chump on its own codebase (T1.x dogfood tasks). Items here block
self-improvement work and deserve priority over the Phase G research backlog in
[ROADMAP_POST_PHASE_F.md](ROADMAP_POST_PHASE_F.md).

**Last updated:** 2026-04-15

Cross-reference: [DOGFOOD_LOG.md](DOGFOOD_LOG.md) for per-run notes.

---

## Shipped this pass (2026-04-15 dogfood session)

| Fix | Commit | Bug |
|-----|--------|-----|
| `CHUMP_TOOL_TIMEOUT_SECS` env override | `6b92cfc` | 30s default too short for 2 tok/s local inference; model timed out mid-call. |
| `patch_file` registered in `LIGHT_CHAT_TOOL_KEYS` | `6b92cfc` | Light mode rejected correct model calls as "Unknown tool" even when the diff was valid. |
| `patch` crate panic guarded with `catch_unwind` | `01de3b6` | Upstream `patch-0.7.0` panics on some LLM-malformed diffs instead of returning `Err`; abort-on-panic killed the agent loop. |
| Default `CHUMP_OLLAMA_NUM_CTX` 4096 → 8192 | `01de3b6` | Ollama silently drops connections when prompt+tool schemas exceed `num_ctx`; manifested as sporadic "model HTTP unreachable" after 3–4 turns. |
| Qwen3 `<think>...</think>` block stripping | `f35918f` | `thinking_strip` only matched `<thinking` prefix (9 chars). Qwen3 emits 5-char `<think>` tag. Blocks accumulated across turns and pushed tool-call context out of the 8K window, causing 25-iteration `patch_file` loops on qwen3:8b. |
| `spawn_blocking` isolation for patch parse | `f35918f` | `catch_unwind` in async context let panics in the upstream `patch` crate unwind through tokio internals and corrupt the HTTP client pool, causing sporadic "model HTTP unreachable" on subsequent requests. Moved parse+apply to `tokio::task::spawn_blocking`. |
| `/no_think` inject in CLI system prompt | `f35918f` | Qwen3 emits ~600 tokens of `<think>` reasoning per turn by default. With tight completion budgets the model ran out of tokens before producing a tool call. Inject `/no_think` unless `CHUMP_THINKING=1` or `CHUMP_CASCADE_ENABLED=1`. |
| `LIGHT_PROFILE_CRITICAL_TOOLS` test guard | `735b8fb` | Stops the silent "tool missing from light profile" regression class. New `LIGHT_PROFILE_CRITICAL_TOOLS` const in `src/tool_inventory.rs` plus 4 tests assert that every critical tool (read_file, list_dir, patch_file, write_file, run_cli, task, memory_brain, episode) appears in `LIGHT_CHAT_TOOL_KEYS`, plus that both lists stay sorted/dedup'd. Adding a new critical tool now requires updating both lists; CI catches anyone who forgets. |
| Consecutive-failing-tool circuit breaker | `735b8fb` | New `BatchOutcome { success_count, fail_count }` returned from `ToolRunner::run_synthetic_batch` and `run_native_batch`. `IterationController` short-circuits with a clear error after 3 consecutive batches where every tool call returned `DENIED:` or `Tool error:` (was 25 — the qwen3:8b loop budget). Threshold tunable via `CHUMP_MAX_CONSECUTIVE_TOOL_FAILS`. Schema-validation pre-flight failures count as fast-fails. Any successful batch resets the counter. |

---

## Still open

### T1.1 model quality matrix (24GB M4)

| Model | Path | Status | Notes |
|-------|------|--------|-------|
| `qwen2.5:7b` | Ollama | **Pass** (2026-04-15) | First clean read→patch→respond. Tool call quality weak — often falls back to `write_file` for full-file rewrites instead of minimal diffs. |
| `qwen2.5:14b` | Ollama | Partial | Can dispatch tools but RAM pressure + cargo builds starve Ollama; model gets evicted mid-run. |
| `qwen3:8b` (Q4_K_M) | Ollama | **Blocked by upstream Ollama instability** | 25-iter loop fixed by `<think>` strip + spawn_blocking + `/no_think`. New blocker: Ollama server itself crashes/restarts mid-session on 24GB M4 (see `/opt/homebrew/var/log/ollama.log` for "Listening on..." restarts). Not a Chump bug — competes with cargo builds and chump-brain for unified memory. Workaround: use `qwen2.5:7b` instead, or run with `CHUMP_BRAIN_AUTOLOAD=` (empty) and no concurrent cargo. |
| `Qwen3.5-9B-OptiQ-4bit` | vLLM-MLX | Correct diffs, server unstable | Produced proper unified diffs (run 4) but vLLM-MLX segfaults under sustained load. |
| `Qwen3-14B-4bit` | vLLM-MLX | Too slow | ~0.5 tok/s triggers tool timeouts. |

**Goal:** one local model that reliably completes T1.1 end-to-end with a minimal patch (not a write_file fallback). Today: `qwen2.5:7b` passes the "no crash" bar only.

### Patch robustness on LLM-malformed diffs

The `catch_unwind` guard stops the panic from aborting the process, but the
upstream `patch` crate's default panic hook still writes "bug: failed to parse
entire input…" to stderr. This pollutes dogfood logs and streaming token
output. A process-wide panic hook swap was considered and rejected as
thread-unsafe. Options:

1. Fork `patch-0.7.0` to return `Err` instead of panicking (cleanest).
2. Replace with `diffy` (different license, different behavior on malformed input).
3. Accept cosmetic stderr noise (current).

### HTTP client heuristics

`CHUMP_OLLAMA_NUM_CTX` default of 8192 is safe for most sessions but may still
be too small once `chump-brain` autoload grows. No runtime awareness of actual
token counts in the prompt — we could warn when assembled prompt exceeds
`num_ctx * 0.8`.

### `gh_pr_list_comments` (carried over from CLOSING_THE_GAPS Gap 3.3)

Chump can post comments but cannot read comments back from GitHub PRs. Blocks
the "respond to reviewer feedback" workflow.

---

## Out of scope for this doc

- Phase G research frontier (quantum, TDA, workspace merge) — see [ROADMAP_POST_PHASE_F.md](ROADMAP_POST_PHASE_F.md).
- Product roadmap (DOSSIER, EXTERNAL_PLAN_ALIGNMENT) — tracked separately.
- ADR-001 transactional speculation — gated on product pain, not dogfood reliability.
