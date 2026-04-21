# Ollama speed tuning (for Chump)

Ways to push more speed out of Ollama when running Chump on a Mac.

## 1. Start Ollama with speed-focused env vars

Run Ollama with these set **before** `ollama serve` (or use the script below):

| Variable | Speed-oriented value | Effect |
|----------|---------------------|--------|
| `OLLAMA_CONTEXT_LENGTH` | `2048` | Smaller context = faster token generation and less RAM. Use `4096` if you need longer conversations. |
| `OLLAMA_KEEP_ALIVE` | `5m` or `-1` | Keeps the model loaded so the **first** Chump reply is fast (no load delay). `-1` = keep indefinitely. |
| `OLLAMA_NUM_PARALLEL` | `2` | Allows 2 concurrent requests; can help if multiple messages are sent close together. |

Example (paste into terminal or add to your shell profile if you always want this when starting Ollama):

```bash
export OLLAMA_CONTEXT_LENGTH=2048
export OLLAMA_KEEP_ALIVE=5m
export OLLAMA_NUM_PARALLEL=2
ollama serve
```

To **free RAM** when you're done: use `OLLAMA_KEEP_ALIVE=0` or run `./scripts/ollama-restart.sh` after stopping with `pkill -f ollama`.

## 2. Use the speed startup script

From the Chump repo:

```bash
./scripts/ollama-serve-fast.sh
```

This starts `ollama serve` in the background with the speed env vars above. Logs go to `/tmp/ollama-serve.log`.

## 3. Apple Silicon (M1/M2/M3/M4)

- **Metal** is used by default; no extra config needed.
- **Unified memory**: the model runs in GPU-accessible memory. Smaller context and smaller models use less memory and can run faster.
- **Update Ollama**: newer versions (0.17+) have better Apple Silicon performance and optional KV cache quantization.

## 4. Model choice (biggest lever)

| Model | Relative speed | RAM (approx) | Use when |
|-------|----------------|---------------|----------|
| `qwen2.5:3b` | Fastest | ~2 GB | Max speed, simple tasks |
| `qwen2.5:7b` | Fast | ~4–5 GB | Good balance |
| `qwen2.5:14b` | Default | ~9 GB | Best quality for Chump |

To use a faster model with Chump, set in `.env` or when running:

```bash
OPENAI_MODEL=qwen2.5:7b ./run-discord.sh
```

Or in `.env`: `OPENAI_MODEL=qwen2.5:7b`. Then run `ollama pull qwen2.5:7b` once.

## 5. Tradeoffs

- **Smaller `num_ctx` (2048)** → faster and less RAM, but shorter conversation context.
- **`KEEP_ALIVE=5m` or `-1`** → fast first reply, more RAM used when idle.
- **Smaller model (7b/3b)** → faster tokens and less RAM, less capable than 14b.

For maximum speed: `OLLAMA_CONTEXT_LENGTH=2048`, `OLLAMA_KEEP_ALIVE=5m`, and `qwen2.5:7b` (or `3b`). For best quality with Chump, keep `qwen2.5:14b` and only tune context/keep_alive.

## 6. MacBook Air M4, **24 GB** unified (typical “dogfood + IDE + browser”)

This class shares **one** pool of RAM for CPU, GPU, and every app. OOMs usually mean **model weights + KV cache + macOS + Cursor/Chrome** exceeded ~24 GB, or **two** heavy inference processes (e.g. Ollama **and** vLLM-MLX) ran together.

| Goal | Model / stack | Notes |
|------|----------------|--------|
| **Default (stable)** | **`qwen2.5:7b`** or **`qwen3:4b`** / **`qwen3:8b`** (if your Ollama catalog has them) on **11434** | Enough headroom for Chump + dogfood + normal desktop apps. Prefer **`OLLAMA_NUM_PARALLEL=1`**. |
| **Higher quality (tight)** | **`qwen2.5:14b`** on **11434** | Often workable with **`OLLAMA_CONTEXT_LENGTH=2048`**, **`OLLAMA_NUM_PARALLEL=1`**, and shed load ([GPU_TUNING.md](GPU_TUNING.md) §1). Quit browsers/Slack first. |
| **vLLM-MLX 14B on 8000** | See [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) + [STEADY_RUN.md](STEADY_RUN.md) | Use conservative **`VLLM_MAX_TOKENS=4096`**, **`VLLM_CACHE_PERCENT=0.12`**, **`VLLM_MAX_NUM_SEQS=1`**. **Stop Ollama** when using 8000 so only one stack holds the GPU ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §1). |
| **Avoid** | Two concurrent **14B** stacks, **`OLLAMA_NUM_PARALLEL=2`** with **14b**, huge `num_ctx` (8192+) on 14b | Common crash / swap thrash patterns on 24 GB. |

**Startup for Ollama on this hardware:** `./scripts/ollama-serve-m4-air-24g.sh` — same ideas as `ollama-serve-fast.sh` but **`OLLAMA_NUM_PARALLEL=1`** and logs **`logs/ollama-serve.log`** (repo-relative when run from repo root).

**`.env` starting point (Ollama):**

```bash
OPENAI_API_BASE=http://127.0.0.1:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:7b
```

Raise to **`qwen2.5:14b`** only after a few stable sessions at 7b, or when you have run **`./scripts/enter-chump-mode.sh`** and closed heavy apps.
