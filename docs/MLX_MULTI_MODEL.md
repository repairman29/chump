# Best multi-model MLX setup on this machine

vLLM-MLX loads **one model per process**. To use multiple MLX models at once you run **one server per port** — each model gets its own port when running at the same time.

## Chump model mix (recommended)

Pre-download the mix so models are cached, then start servers on separate ports:

```bash
./scripts/download-mlx-models.sh   # 30B, 7B, 3B — one at a time on 8000, then exits
```

| Role        | Model                                    | Port (when running) | Rough size |
| ----------- | ---------------------------------------- | ------------------- | ---------- |
| Main        | `mlx-community/Qwen3-30B-A3B-4bit-DWQ`   | 8000                | ~17 GB     |
| Worker/fast | `mlx-community/Qwen2.5-7B-Instruct-4bit` | 8001                | ~4.5 GB    |
| Small       | `mlx-community/Qwen2.5-3B-Instruct-4bit` | 8002 (optional)     | ~1.8 GB    |

- **One port per model** if they run at the same time (8000, 8001, 8002, …).
- Chump main: `OPENAI_API_BASE=http://localhost:8000/v1`. Worker (delegate): `CHUMP_WORKER_API_BASE=http://localhost:8001/v1` and `CHUMP_WORKER_MODEL` as needed.
- To run 3B on 8002: `PORT=8002 VLLM_MODEL=mlx-community/Qwen2.5-3B-Instruct-4bit ./serve-vllm-mlx.sh` (in a third terminal or background).
- Override the mix: `CHUMP_MLX_MODELS="model1 model2" ./scripts/download-mlx-models.sh`.

## Memory (MacBook Air / typical Mac)

- **8 GB:** One small model only (e.g. 3B 4-bit ~2GB). Two models only if both are tiny.
- **16 GB:** Two smaller models (e.g. 3B + 7B 4-bit) or one 30B 4-bit (~17GB, tight).
- **24 GB+:** 30B on one port + 7B on another, or 7B + 3B comfortably.

**Why memory gets eaten so fast:** See [MEMORY_AND_PROCESSES.md](MEMORY_AND_PROCESSES.md) for what uses RAM in this stack and how to free it (kill 8000/8001, embed server, and why macOS unified memory may not show “free” right away).

**If the Python embed server (port 18765) keeps crashing:** The LLM servers on 8000/8001 can use most of RAM (30B ~17 GB, 7B ~4.5 GB). With both running there is little left for the embed process; the system may kill it under memory pressure. Options: (1) Use **in-process embeddings** (`cargo build --features inprocess-embed`, leave `CHUMP_EMBED_URL` unset) so no Python embed server runs. (2) Use a **smaller main model on 8000**: e.g. `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit ./serve-vllm-mlx.sh` so 8000 uses ~4.5 GB instead of ~17 GB, leaving headroom for the embed server.

## 30B only (free ~4.5 GB for testing / embed server)

To run only the 30B model on 8000 and free the ~4.5 GB that 8001 would use:

- **Start only 8000:** Run `./serve-vllm-mlx.sh` (or let warm-the-ovens start it). Do **not** run `./scripts/serve-vllm-mlx-8001.sh` and do **not** set `WARM_PORT_2` in `.env`.
- **Delegate tool:** With only 8000 running, leave `CHUMP_WORKER_API_BASE` unset; the worker will use 8000 (same 30B). If you set `CHUMP_DELEGATE=1`, the delegate tool will use 8000 unless you explicitly set `CHUMP_WORKER_API_BASE=http://localhost:8001/v1`.
- **Chump Menu:** Do not start "vLLM-MLX (8001)"; only 8000 needs to be warm.
- **Heartbeat / preflight:** Preflight prefers 8000 and only falls back to 8001 if 8000 is down, so with 8000 up you're fine.

## Option 1: Two vLLM-MLX servers

Same stack you already use; no new Python deps. Two terminals, two one-line commands.

**Terminal 1 – 30B on port 8000:**

```bash
cd rust-agent
./serve-vllm-mlx.sh
# → http://localhost:8000
```

**Terminal 2 – 7B on port 8001:**

```bash
cd rust-agent
./scripts/serve-vllm-mlx-8001.sh
# → http://localhost:8001
```

**Use from Chump:**

- 30B: `./run-best.sh --chump "prompt"`
- 7B: `OPENAI_API_BASE=http://localhost:8001/v1 ./run-best.sh --chump "prompt"`

Override the second model/port: `VLLM_MODEL=mlx-community/Qwen2.5-3B-Instruct-4bit PORT=8002 ./scripts/serve-vllm-mlx-8001.sh`

## Option 2: Script to start two servers

From repo root:

```bash
./scripts/serve-multi-mlx.sh
```

Starts 7B on 8000 and 3B on 8001 (or adjust models/ports in the script). Use different terminals or run in background; see script comments for memory notes.

## Option 3: One server, multiple models (mlx-openai-server)

**mlx-openai-server** can serve multiple models in one process and route by model ID (OpenAI-compatible). You’d install it separately and configure a YAML with 2–3 models; Chump would call the same base URL and pass different `model` names. This is optional; if vLLM-MLX is already working for you, Option 1 is simpler and consistent with the rest of the repo.

## Summary

- **Best multi-model setup with MLX on this machine:** two vLLM-MLX processes (two ports), e.g. 7B on 8000 + 3B on 8001 (16GB) or 30B on 8000 + 7B on 8001 (24GB).
- Chump stays single-model per run; you choose which model by setting `OPENAI_API_BASE` (and optionally `OPENAI_MODEL`) before running Chump.
