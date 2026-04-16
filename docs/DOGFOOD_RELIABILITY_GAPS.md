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
| Qwen3 `<think>...</think>` block stripping | pending | `thinking_strip` only matched `<thinking` prefix (9 chars). Qwen3 emits 5-char `<think>` tag. Blocks accumulated across turns and pushed tool-call context out of the 8K window, causing 25-iteration `patch_file` loops on qwen3:8b. |

---

## Still open

### T1.1 model quality matrix (24GB M4)

| Model | Path | Status | Notes |
|-------|------|--------|-------|
| `qwen2.5:7b` | Ollama | **Pass** (2026-04-15) | First clean read→patch→respond. Tool call quality weak — often falls back to `write_file` for full-file rewrites instead of minimal diffs. |
| `qwen2.5:14b` | Ollama | Partial | Can dispatch tools but RAM pressure + cargo builds starve Ollama; model gets evicted mid-run. |
| `qwen3:8b` (Q4_K_M) | Ollama | **Regression** fixed pending verification | 25-iter `patch_file` loops pre-`<think>` strip. Post-strip: pending rerun. |
| `Qwen3.5-9B-OptiQ-4bit` | vLLM-MLX | Correct diffs, server unstable | Produced proper unified diffs (run 4) but vLLM-MLX segfaults under sustained load. |
| `Qwen3-14B-4bit` | vLLM-MLX | Too slow | ~0.5 tok/s triggers tool timeouts. |

**Goal:** one local model that reliably completes T1.1 end-to-end with a minimal patch (not a write_file fallback). Today: `qwen2.5:7b` passes the "no crash" bar only.

### Tool registration drift

`LIGHT_CHAT_TOOL_KEYS` in `src/tool_inventory.rs` has to be kept in sync with
the full profile by hand. Missing `patch_file` was a silent failure: the model
correctly produced a valid diff and Chump rejected it as an unknown tool. There
is no test asserting that the light profile contains every tool the agent loop
considers essential.

**Fix idea:** assert at build time (or via a test) that the light profile
contains the tools enumerated in a `LIGHT_PROFILE_CRITICAL_TOOLS` constant.

### Iteration-cap vs fast-failing tools

`IterationController::max_iterations = 25` counts *every* tool call, not
distinguishing between:

- tool returned useful output (model can progress)
- tool returned an error (model can self-correct)
- tool "returned" in 1-3ms (pure failure; model is storming)

The qwen3:8b regression surfaced this: 25 `patch_file` calls each completing in
1-3ms burned the full iteration budget without producing output. A separate
"consecutive-failing-tool-call" circuit breaker with a lower cap (say 3) would
short-circuit faster and surface a clearer error to the caller.

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
