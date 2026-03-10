# rust-agent

Minimal local AI agent using [AxonerAI](https://crates.io/crates/axonerai) (Rust) and an OpenAI-compatible HTTP API. Best setup per the Fast Local AI doc / plan: **vLLM-MLX** with a **4-bit DWQ 30B** model on Apple Silicon (continuous batching, best throughput; no paid API).

**Recent improvements:** Chump Menu (v1.1) — Start/Stop for MLX 8001, embed server status refreshes until warm, single-instance guard so only one Discord bot runs (no duplicate replies). Delegate worker can use a smaller model via `CHUMP_WORKER_API_BASE` / `CHUMP_WORKER_MODEL`. Delegate task type **extract** (entities/facts) in addition to summarize. In-process embeddings (fastembed) build on stable Rust; malformed tool JSON is logged.

## Build

```bash
cargo build --release
```

For a full local check (build, test, clippy) before pushing, run `./scripts/check.sh`. CI runs the same steps when `rust-agent/` or the workflow file changes (see `.github/workflows/rust-agent.yml`).

The release binary is `target/release/rust-agent` (or `target/release/chump` if renamed). Use `./run-best.sh` for dev (cargo run) or run the binary directly with the same env vars for production.

## Best setup: vLLM-MLX + 30B 4-bit DWQ (plan/doc recommended)

This matches the plan: native MLX inference, 21–87% better throughput than llama.cpp/Ollama, 30B model in ~17GB so it fits a 24GB M4 Mac.

### 1. Install vLLM-MLX

**With uv (recommended):**

```bash
uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'
# If vllm-mlx not found, add uv’s tool dir to PATH:
export PATH="$HOME/.local/bin:$PATH"
```

**With pip:**

```bash
pip install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'
```

### 2. Optional: raise GPU memory limit (for 30B on 24GB Mac)

```bash
sudo sysctl iogpu.wired_limit_mb=20480
```

### 3. Start the server with the 30B DWQ model

```bash
# From this repo (or use the script):
./serve-vllm-mlx.sh
# Or manually:
vllm-mlx serve mlx-community/Qwen3-30B-A3B-4bit-DWQ --port 8000
```

First run downloads the model (~17GB). To pre-download the full Chump mix (30B, 7B, 3B) in one go, run `./scripts/download-mlx-models.sh`. Server listens at `http://localhost:8000/v1`.

**30B only (recommended to free ~4.5 GB):** Run only 8000; do not start 8001. Delegate and heartbeat will use 8000. See [docs/MLX_MULTI_MODEL.md](docs/MLX_MULTI_MODEL.md)#30b-only. For **multiple MLX models at once** (one port per model), see the rest of that doc and `./scripts/serve-multi-mlx.sh`.

### 4. Run the agent against vLLM-MLX

In another terminal:

```bash
./run-best.sh
# Or manually:
export OPENAI_API_BASE=http://localhost:8000/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL=default
cargo run
```

---

## Quick fallback: Ollama

If you want something running in a few minutes without Python/vLLM-MLX:

1. Install and start [Ollama](https://ollama.com) (`brew install ollama`, then run the app or `ollama serve`).
2. Pull a model: `ollama pull llama3.2:1b` (or `llama3.2:3b`, `qwen2.5:7b`).
3. Run: `./run-local.sh`

Ollama is easier to install but uses llama.cpp under the hood; vLLM-MLX is the doc’s preferred engine for best throughput and quality.

### If you see "close to the maximum recommended size" (30B on 24GB Mac)

The 30B 4-bit model uses ~16GB; on a 24GB Mac you're near the recommended limit, so the stack may warn that it can be slow. You can:

- **Ignore it** if generation speed is acceptable.
- **Offload memory** by limiting context length (smaller KV cache, fewer tokens per request):
  ```bash
  export VLLM_MAX_MODEL_LEN=8192
  ./serve-vllm-mlx.sh
  ```
  Try `8192` or `4096`; Chump rarely needs huge context in one go.
- **Use a smaller model** to avoid the warning and free memory (faster load, slightly lower quality):
  ```bash
  export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit
  ./serve-vllm-mlx.sh
  ```
  Chump works the same; point `OPENAI_API_BASE` at port 8000 as usual.

### If you see "Insufficient Memory" or "kIOGPUCommandBufferCallbackErrorOutOfMemory"

The 30B model is too large for your GPU (e.g. MacBook Air). Use a **smaller model** or **lower context** (see "close to the maximum recommended size" above): e.g. `export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit` or `export VLLM_MAX_MODEL_LEN=4096` before `./serve-vllm-mlx.sh`.

### If the server on port 8000 crashes or Chump says "connection closed"

If `./serve-vllm-mlx.sh` exits immediately or Chump reports `connection closed before message completed`, the vLLM-MLX process likely crashed during **Metal/GPU init**. Typical crash:

```
*** Terminating app due to uncaught exception 'NSRangeException', reason: '*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array'
```

(stack trace in `libmlx.dylib` → `mlx::core::metal::Device`)

**Do this:**

1. **Use Ollama instead (fastest fix).** No Python/vLLM-MLX needed; Chump works the same:

   ```bash
   ollama pull qwen2.5:7b
   ./run-local.sh --chump "Your prompt"
   ```

2. **If you want to keep using vLLM-MLX:**
   - The serve script sets `VLLM_WORKER_MULTIPROC_METHOD=spawn`; if you start the server manually, set it too.
   - **CPU-only (avoids Metal):** `export MLX_DEVICE=cpu` then `./serve-vllm-mlx.sh` (slower but often stable).
   - **Smaller model (often more stable):** `export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit` then `./serve-vllm-mlx.sh`.
   - Run the server from a normal Terminal (not only from an IDE) so you see full logs; retry after a reboot if the Mac was under load.

---

## Other OpenAI-compatible servers

Point the agent at any server that exposes the OpenAI chat completions API:

```bash
export OPENAI_API_BASE=http://localhost:PORT/v1
export OPENAI_API_KEY=your-key-or-placeholder
export OPENAI_MODEL=model-name
cargo run
```

If `OPENAI_API_BASE` is not set, the agent uses the default **OpenAI** API (requires a real `OPENAI_API_KEY`).

## Env vars

| Variable                 | When to use                                                                  | Example                                                                                                                                     |
| ------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `OPENAI_API_BASE`        | Local server                                                                 | `http://localhost:8000/v1` (vLLM-MLX) or `http://localhost:11434/v1` (Ollama)                                                               |
| `OPENAI_API_KEY`         | Any (vLLM-MLX ignores it; use `ollama` for Ollama)                           | `not-needed`, `ollama`, or your OpenAI key                                                                                                  |
| `OPENAI_MODEL`           | Model name the server expects                                                | `default` (vLLM-MLX single-model), `llama3.2:1b` (Ollama), etc.                                                                             |
| `CHUMP_EMBED_URL`        | Semantic memory (optional)                                                   | `http://127.0.0.1:18765` when running `scripts/start-embed-server.sh`; unset to use in-process when built with `--features inprocess-embed` |
| `CHUMP_EMBED_INPROCESS`  | Prefer in-process embedding (requires `inprocess-embed` feature)             | `1` to use fastembed even when `CHUMP_EMBED_URL` is set                                                                                     |
| `CHUMP_EMBED_CACHE_DIR`  | Where to cache the in-process embed model (optional)                         | Path to a directory; default is fastembed cache                                                                                             |
| `VLLM_MAX_MODEL_LEN`     | Lower memory (smaller KV cache)                                              | `8192` or `4096` when running `serve-vllm-mlx.sh`                                                                                           |
| `CHUMP_DELEGATE`         | Enable orchestrator–worker: add `delegate` tool (e.g. summarize)             | `1` or `true`; see [docs/ORCHESTRATOR_WORKER.md](docs/ORCHESTRATOR_WORKER.md)                                                               |
| `CHUMP_WORKER_API_BASE`  | Delegate worker endpoint (optional)                                          | e.g. `http://localhost:8001/v1` for a smaller model; falls back to `OPENAI_API_BASE` if unset                                               |
| `CHUMP_WORKER_MODEL`     | Delegate worker model (optional)                                             | Model name for worker; falls back to `OPENAI_MODEL` if unset                                                                                |
| `TAVILY_API_KEY`         | Web search (Tavily) for research and self-improvement; limited credits/month | Get key at tavily.com; set in `.env` (never commit). Chump uses `web_search` tool when set.                                                 |
| `CHUMP_READY_DM_USER_ID` | Discord user ID to receive a "Chump is online" DM when the bot connects      | Enable Developer Mode → right-click your profile → Copy User ID; set in `.env`.                                                             |

## Testing the agent

- **Single-shot:** pass a message as the first argument:  
  `./run-best.sh "Explain recursion in one sentence."`
- **Interactive chat:** run with no arguments. You get a REPL with conversation history (stored under `./sessions/repl`). Type `quit` or `exit` to stop.

Use `./run-best.sh` (with vLLM-MLX on port 8000) or `./run-local.sh` (Ollama) so the agent talks to your local model.

### Chump CLI (full tools + soul)

Same tools and soul as the Discord bot, but from the terminal (no Discord token):

- **Single-shot:** `./run-local.sh --chump "What's in this repo? List top-level."`
- **Interactive:** `./run-local.sh --chump` then type messages; `quit` or `exit` to stop.

Session and memory live under `./sessions/cli` and `sessions/chump_memory.json`. For best final replies (natural-language summaries after tool use), use a larger model (e.g. vLLM-MLX 30B or Ollama `qwen2.5:7b`); very small models may sometimes return raw JSON instead of a summary.

---

## Discord bot

The binary can run as a Discord bot: it replies in **DMs** and in **channels when the bot is @mentioned**. The same local model (vLLM-MLX or Ollama) is used for replies.

### Run the Discord bot

1. **Token:** Set your bot token in the environment (never commit it). Create a bot at [Discord Developer Portal](https://discord.com/developers/applications) → your app → Bot → copy token.

   ```bash
   export DISCORD_TOKEN="your-bot-token"
   ```

   If you ever pasted your token in chat or in a file, regenerate it in the portal and use the new value only in env.

2. **Intents:** In the portal, Bot → enable **Message Content Intent** (required to read message text).

3. **Invite:** OAuth2 → URL generator, scopes `bot`, permissions e.g. “Send Messages”, “Read Message History”, “View Channels”. Invite the bot to your server.

4. **Start the agent + Discord:** With your local model server running (e.g. `./serve-vllm-mlx.sh` or Ollama), run:

   ```bash
   ./run-discord.sh
   ```

   That script loads `DISCORD_TOKEN` from `.env` (gitignored) and uses the same local model env as `run-best.sh`. Or set `DISCORD_TOKEN` yourself and run `./run-best.sh --discord`.

   **Making Chump smarter:** Chump has a default personality and purpose and per-channel memory. Override with `CHUMP_SYSTEM_PROMPT`. See [docs/CHUMP_IDENTITY.md](docs/CHUMP_IDENTITY.md) for soul, purpose, heartbeat, and how to expand.

   **CLI/exec:** Chump has CLI access by default. Optional: `CHUMP_CLI_ALLOWLIST` / `CHUMP_CLI_BLOCKLIST`. He’s prompted to make plans and execute with your guidance.

   **Memory and logs:** Chump has a long-term `memory` tool (store/recall) and appends activity to `logs/chump.log`. See [docs/CHUMP_IDENTITY.md](docs/CHUMP_IDENTITY.md).

   **Semantic memory (local):** For recall by meaning, run the local embed server. On **Homebrew Python** (externally-managed), use a venv: `python3 -m venv .venv` then `.venv/bin/pip install -r scripts/requirements-embed.txt`; `./scripts/start-embed-server.sh` will use `.venv/bin/python3` if present. Otherwise `pip3 install -r scripts/requirements-embed.txt` then `./scripts/start-embed-server.sh`. Optional: `CHUMP_EMBED_URL=http://127.0.0.1:18765`. **If the Python embed server keeps crashing**, build with `cargo build --features inprocess-embed` and leave `CHUMP_EMBED_URL` unset—embeddings run in-process (no Python). The agent also chunks backfill requests (max 32 per call) and the embed server caps batch size (default 64) to reduce load. **Large LLMs on 8000/8001** (e.g. 30B on 8000 ~17 GB, 7B on 8001 ~4.5 GB) can leave little RAM for the embed server and cause it to be killed; use a smaller main model (e.g. `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit ./serve-vllm-mlx.sh`) or in-process embeddings. See [docs/CHUMP_SMART_MEMORY.md](docs/CHUMP_SMART_MEMORY.md) and [docs/MLX_MULTI_MODEL.md](docs/MLX_MULTI_MODEL.md).

   **Project/repo mode:** For building and organizing projects, set `CHUMP_PROJECT_MODE=1` before starting; see [docs/USER_STORIES.md](docs/USER_STORIES.md) for 20 example user stories.

   **Web search (Tavily):** Set `TAVILY_API_KEY` in `.env` (get a key at tavily.com; e.g. 1000 credits/month). Chump then has a `web_search` tool for research and self-improvement; he will store learnings in memory. Never commit the key.
   **Overnight heartbeat:** Run `./scripts/heartbeat-learn.sh` for 8 hours (configurable); Chump runs learning rounds using Tavily and stores new skills in memory. See [docs/CHUMP_SERVICE.md](docs/CHUMP_SERVICE.md) §4.
   **Testing the heartbeat:** Check model server: `./scripts/check-heartbeat-preflight.sh` (prints 8000 or 8001, or exits 1). Quick run (2m, 15s interval): `HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-learn.sh`. Smoke test (1m, checks preflight + one round + completion): `./scripts/test-heartbeat-learn.sh`. Optional retry per round: `HEARTBEAT_RETRY=1 ./scripts/heartbeat-learn.sh`. **Autonomy tiers:** Run `./scripts/run-autonomy-tests.sh` to validate tools, research, multi-step, and sustain; passing tiers releases more autonomous behavior (see [docs/CHUMP_AUTONOMY_TESTS.md](docs/CHUMP_AUTONOMY_TESTS.md)).

   **Ready DM:** Set `CHUMP_READY_DM_USER_ID` in `.env` to your Discord user ID (Developer Mode → right-click your profile → Copy User ID). When the bot connects, Chump will send you a DM: "Chump is online and ready to chat."

   **Minimal Chump + warm the ovens:** Keep only the Discord bot running (no MLX servers). On the first message, Chump starts the model server(s) on demand and then replies. Set `CHUMP_WARM_SERVERS=1` and run `./run-discord.sh`; see [docs/CHUMP_SERVICE.md](docs/CHUMP_SERVICE.md) for service setup so Chump stays up across sleep/wake.

   **Menu bar app:** Build a small app for the top nav to start/stop Chump and see status (online, model port). See [ChumpMenu/README.md](ChumpMenu/README.md) and `./scripts/build-chump-menu.sh`.

---

## Extending

- Add tools via AxonerAI’s `ToolRegistry` and pass them into `Agent::new`.
- Session state: interactive mode already uses `FileSessionManager`; single-shot is stateless.
- See [AxonerAI](https://github.com/Manojython/axonerai) for provider and tool docs.
