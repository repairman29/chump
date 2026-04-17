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
| `dogfood-run.sh` preserves caller `CHUMP_*` env | `0148eb7` | Script sourced `.env` after snapshotting only `OPENAI_MODEL`/`OPENAI_API_BASE`, so `CHUMP_OLLAMA_NUM_CTX=8192 ./scripts/dogfood-run.sh ...` was silently clobbered by the `.env`'s `2048`. Now preserves 10 commonly-tuned `CHUMP_*` vars across the `.env` source. macOS bash 3.2 compatible. |
| `gh_pr_list_comments` tool (closes Gap 3.3) | `0148eb7` | Chump could post PR comments but not read reviewer feedback. New tool merges issue-level + inline review comments into plain-text a 7B model can parse. Supports `since_iso` filter + 30/100 limit clamp. Gated on `git_tools_enabled`. |
| One-shot panic-hook filter for patch crate | `0148eb7` | `catch_unwind` caught the panic but the default panic hook still wrote "bug: failed to parse entire input..." to stderr, polluting dogfood logs. Now a process-wide `std::sync::Once`-guarded hook silently drops those specific patch-parser panic messages; other panics flow through to the captured original hook. |
| `num_ctx` overflow early warning | `0148eb7` | `warn_if_near_num_ctx` in `local_openai.rs` fires when estimated prompt size exceeds `num_ctx * 0.8`, so users see the overflow coming instead of getting opaque "model HTTP unreachable" when Ollama silently drops the connection. Suppress with `CHUMP_NUM_CTX_WARN=0`. |

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

### Ollama stability on 24GB M4 (upstream, not Chump)

Ollama `0.20.7` segfaults under dogfood load on 24GB M4 — observed with both
`qwen2.5:7b` and `qwen3:8b`. The server responds `500` to `/v1/chat/completions`
after ~13s, then restarts (`"Listening on 127.0.0.1:11434"` appears in
`/opt/homebrew/var/log/ollama.log`). System has 24 GiB total / ~12 GiB free
when inference starts; concurrent cargo builds push it over. Not fixable from
Chump — the circuit breaker (`735b8fb`) short-circuits with a clear error
instead of looping when this happens. Workarounds: more swap, `CHUMP_BRAIN_AUTOLOAD=`
empty, or larger RAM.

### Patch crate ergonomics (deferred — REL-003)

**Status:** Deferred 2026-04-17. See `gaps.yaml` REL-003 for the full decision.

The `patch-0.7.0` crate is effectively abandoned upstream (last release
2022-12-28, no repo activity), but our three-layer mitigation is sufficient:

1. `catch_unwind` in `src/patch_apply.rs::parse_single_file_patch`
   (commit `01de3b6`).
2. `spawn_blocking` wrapper in `src/repo_tools.rs::patch_file` isolates
   the panic to a dedicated tokio worker (commit `f35918f`).
3. Dedicated panic-hook filter silences "bug: failed to parse entire
   input" stderr noise (commit `0148eb7`).

Coverage pinned by `patch_apply::tests::malformed_diff_does_not_panic`.

**Re-open conditions:** new panic pattern escapes our guard, upstream
publishes a Result-returning API, or a more fundamental diff-apply bug
we can't patch over.

### Prompt-token estimation accuracy

`warn_if_near_num_ctx` uses a fast-but-rough heuristic (bytes/3.5) instead of
a real tokenizer. Good enough for "you're approaching the limit" but can be
off by ±30% on code-heavy prompts. Not worth a tiktoken dependency unless the
warning proves to be systematically wrong.

---

## Out of scope for this doc

- Phase G research frontier (quantum, TDA, workspace merge) — see [ROADMAP_POST_PHASE_F.md](ROADMAP_POST_PHASE_F.md).
- Product roadmap (DOSSIER, EXTERNAL_PLAN_ALIGNMENT) — tracked separately.
- ADR-001 transactional speculation — gated on product pain, not dogfood reliability.
