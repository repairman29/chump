# T1.1 — fixed model probe (task stays open until the system passes)

**T1.1 is not “skipped” when a probe fails.** A failed run means: keep the same task, try another model (or improve prompts / brain / parser), log it, repeat until **objective verify** passes.

## What “done” means for T1.1

Same as [DOGFOOD_TASKS.md](DOGFOOD_TASKS.md) **T1.1 verify**: no `SESSION_OVERRIDES.lock().expect` in `src/policy_override.rs`, and `cargo test --bin chump` passes.

## One command per model

From repo root (Ollama or your `OPENAI_API_BASE` must answer preflight). For **vLLM-MLX** after a restart or first-time weight pull, run **`./scripts/wait-for-vllm.sh`** before the probe so **`check-heartbeat-preflight`** sees **HTTP 200** without spawning a second server.

```bash
chmod +x ./scripts/dogfood-t1-1-probe.sh   # once
OPENAI_MODEL=qwen2.5:14b ./scripts/dogfood-t1-1-probe.sh
OPENAI_MODEL=qwen3:8b ./scripts/dogfood-t1-1-probe.sh
```

- **Always** sets the same prompt as T1.1 (see script header — must stay aligned with `DOGFOOD_TASKS.md`).
- Writes the usual **`logs/dogfood/<timestamp>.log`** via `dogfood-run.sh`.
- Appends one JSON line per attempt to **`logs/dogfood/t1.1-model-probes.jsonl`** (gitignored with `logs/`) for comparing models without editing git.

**Just:**

```bash
just dogfood-t1-1-probe qwen2.5:14b
```

## After each attempt

1. Append a short run block to **`docs/DOGFOOD_LOG.md`** (model, score **PASS** / **FAIL**, what happened).
2. If **FAIL**: adjust **model**, **`chump-brain/rust-codebase-patterns.md`**, or **product** (parser, tools, auto-approve) — then probe again. Do **not** open T1.2 until T1.1 verify passes.
3. If **PASS**: log it, keep Phase 8 / roadmap bookkeeping in sync, **then** move to T1.2.

## Tail logs while probing

```bash
./scripts/tail-model-dogfood.sh
# optional:
CHUMP_TAIL_LOGS=logs/dogfood/t1.1-model-probes.jsonl ./scripts/tail-model-dogfood.sh
```

(`tail` on `.jsonl` is coarse but fine for “did a line land yet”.)
