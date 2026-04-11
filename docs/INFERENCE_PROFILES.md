# Inference profiles — how we operate Chump

This is the **canonical guide** for choosing and running local inference. Pick **one primary profile per machine** unless you are deliberately A/B testing. Documented defaults here match **`scripts/env-max_m4.sh`**, **`docs/STEADY_RUN.md`**, and **`keep-chump-online.sh`** behavior.

---

## 1. Primary profile (recommended for Mac): vLLM-MLX on port **8000**

**What it is:** **`vllm-mlx serve`** serves **MLX-community** models (default **Qwen2.5 14B 4-bit**) with an OpenAI-compatible API on **`http://127.0.0.1:8000/v1`**.

**When to use:** Maximum capability on Apple Silicon, **steady production** runs, full Discord tooling with **in-process embeddings**, alignment with **Farmer Brown / keep-chump-online / oven-tender** automation that targets **8000**.

**Requirements**

| Requirement | Notes |
|-------------|--------|
| **vLLM-MLX CLI** | `command -v vllm-mlx` — install e.g. `uv tool install 'vllm-mlx @ git+https://github.com/waybarrios/vllm-mlx.git'` (see **`serve-vllm-mlx.sh`** header). |
| **Python / uv** | As required by the `vllm-mlx` install. |
| **Disk / network** | First 14B pull is large (~8–9 GB from Hugging Face). Optional **`HF_TOKEN`** in **`.env`** reduces rate limits. |
| **Chump build (full tools)** | `cargo build --release --features inprocess-embed` — used by **`./run-discord-full.sh`**. Semantic memory / embed-dependent tools expect this. |
| **`.env`** | **`OPENAI_API_BASE=http://127.0.0.1:8000/v1`** (or `http://localhost:8000/v1`). **`OPENAI_MODEL`** must match the served model (e.g. **`mlx-community/Qwen2.5-14B-Instruct-4bit`**). **`OPENAI_API_KEY`** can be **`not-needed`** for local servers. |

**Stability defaults (STEADY_RUN)**

Set in **`.env`** so **`serve-vllm-mlx.sh`** and **`scripts/restart-vllm-if-down.sh`** stay aligned:

- **`CHUMP_MAX_CONCURRENT_TURNS=1`** — one Discord/heartbeat turn at a time so **8000** is not overloaded.
- **`CHUMP_MODEL_REQUEST_TIMEOUT_SECS=300`** (optional; default is 300) — long enough for 14B.
- **`VLLM_MAX_NUM_SEQS=1`**, **`VLLM_MAX_TOKENS=4096`**, **`VLLM_CACHE_PERCENT=0.12`** — conservative; raise only after days of stability (see **`docs/STEADY_RUN.md`**).

**Startup order**

1. **Model server:** `./scripts/restart-vllm-if-down.sh` — starts **`./serve-vllm-mlx.sh`** in the background if **8000** is down; logs **`logs/vllm-mlx-8000.log`**.
2. **Wait for readiness:** `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/v1/models` → **200**.
3. **Discord bot (full toolkit):** `./run-discord-full.sh` — ensures restart script ran, builds **release + inprocess-embed**, runs **`./target/release/rust-agent`** (or **`chump`**) **`--discord`**.  
   **Or**, after a manual release build: **`./run-discord.sh`** — prefers release binary (see script).
4. **Web / PWA:** **`./run-web.sh`** — when **`.env`** points at **8000**, it can ensure the model is up before binding (see **`docs/OPERATIONS.md`**).

**Automation (optional)**

- **`./scripts/keep-chump-online.sh`** — if **`OPENAI_API_BASE`** points at **127.0.0.1:8000** or **:8001**, it **skips Ollama** and tends that **vLLM-MLX** port + optionally Discord (**`CHUMP_KEEPALIVE_DISCORD=1`**).
- **launchd** examples: **`scripts/restart-vllm-if-down.plist.example`**, Farmer Brown / roles per **`docs/OPERATIONS.md`**.

### 1a. Lite profile: vLLM-MLX on **8001** (smaller model)

**When to use:** Less unified memory than a comfortable **14B @ 8000** run, or you want a **single** local MLX server without competing with a second 14B process on 8000.

**`.env` example**

```bash
OPENAI_API_BASE=http://127.0.0.1:8001/v1
OPENAI_API_KEY=not-needed
OPENAI_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit
```

**Start / restart**

| Action | Command |
|--------|---------|
| Foreground | **`./scripts/serve-vllm-mlx-8001.sh`** (defaults: **7B**, port **8001**, same throttling flags as **`serve-vllm-mlx.sh`**) |
| Background (cron / recovery) | **`./scripts/restart-vllm-8001-if-down.sh`** — logs **`logs/vllm-mlx-8001.log`** |

**Chump entrypoints:** **`./run-web.sh`**, **`./run-discord-full.sh`**, and **`keep-chump-online`** read **`OPENAI_API_BASE`** via **`scripts/openai-base-local-mlx-port.sh`** and will run **`restart-vllm-8001-if-down.sh`** when the base is **8001**, same pattern as **8000**.

**Ollama vs MLX:** Starting MLX via **`serve-vllm-mlx.sh`**, **`serve-vllm-mlx-8001.sh`**, **`restart-vllm-if-down.sh`**, **`restart-vllm-8001-if-down.sh`**, **`run-web.sh`** (when `.env` points at local **8000/8001**), **`run-discord-full.sh`**, or **`keep-chump-online`** (local MLX mode) runs **`scripts/stop-ollama-if-running.sh`** first so **Ollama is not left running** beside vLLM-MLX on the same GPU.

**Optional:** Run **14B on 8000** and **7B on 8001** in two terminals for A/B; point **`.env`** at only one base at a time for a given Chump process.

**One-shot .env (repo root):** `python3 scripts/apply-mlx-8001-env.py` — appends / replaces the three **`OPENAI_*`** lines under a marker (other keys untouched).

**Operational rules**

- **Do not** point **`OPENAI_API_BASE`** at random ports — use **8000** (vLLM-MLX), **11434** (Ollama), or **8001** where documented; **`scripts/check-heartbeat-preflight.sh`** enforces this for heartbeats.
- **One** inference URL in **`.env`** for normal operation; change it only when switching profiles (see §3).
- After **`.env`** changes, **restart** the Discord (and web) processes.

---

## 2. Secondary profile: **Ollama** on port **11434**

**When to use:** Quick development, minimal setup, or when **vLLM-MLX** is unavailable.

**Requirements:** **`ollama serve`**, **`ollama pull`** for your model (e.g. **`qwen2.5:14b`**).

**`.env` example**

```bash
OPENAI_API_BASE=http://127.0.0.1:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:14b
# Clear or omit CHUMP_TEST_CONFIG=max_m4 if set
```

**Scripts:** **`./run-discord-ollama.sh`** (Ollama reachability check + **`cargo run -- --discord`**), **`./run-local.sh`** for CLI.

**Note:** **`keep-chump-online`** behaves differently when **`.env`** points at **11434** vs **8000** / **8001** (Ollama vs local vLLM-MLX). See **`scripts/keep-chump-online.sh`**.

---

## 3. Switching profiles (checklist)

1. **Stop** the Discord bot: **`./scripts/stop-chump-discord.sh`** or **`pkill -f 'chump.*--discord'`** / **`pkill -f 'rust-agent.*--discord'`**.
2. Edit **`.env`**: set **`OPENAI_API_BASE`**, **`OPENAI_MODEL`**, **`OPENAI_API_KEY`** per §1 or §2.
3. **Primary (8000):** run **`./scripts/restart-vllm-if-down.sh`**. **Lite MLX (8001):** run **`./scripts/restart-vllm-8001-if-down.sh`** or **`./scripts/serve-vllm-mlx-8001.sh`**. **Ollama profile:** ensure **`ollama serve`** and model pulled.
4. **Primary full tools:** `cargo build --release --features inprocess-embed` then **`./run-discord.sh`** or **`./run-discord-full.sh`**.
5. **Ollama quick:** **`./run-discord-ollama.sh`**.

---

## 4. Testing configs without editing `.env` long-term

- **`source scripts/env-max_m4.sh`** — exports **8000** + MLX model + **`CHUMP_TEST_CONFIG=max_m4`** for a shell session.
- **`source scripts/env-default.sh`** — Ollama-style defaults for tests (see **`scripts/run-tests-with-config.sh`**).

---

## 5. Related documentation

| Doc | Topic |
|-----|--------|
| **[STEADY_RUN.md](STEADY_RUN.md)** | vLLM tuning, **`CHUMP_MAX_CONCURRENT_TURNS`**, keepalive, heartbeats |
| **[GPU_TUNING.md](GPU_TUNING.md)** | OOM, Metal, shed-load |
| **[OPERATIONS.md](OPERATIONS.md)** | Run matrix, recovery, ports |
| **[SETUP_AND_RUN.md](SETUP_AND_RUN.md)** | Repo root, scripts |
| **`serve-vllm-mlx.sh`** (repo root) | vLLM-MLX CLI, **`VLLM_*`** env vars |

---

## 6. Binary names (`chump` vs `rust-agent`)

**`Cargo.toml`** may use package name **`rust-agent`**; the binary name is **`chump`**. Release **`target/release/rust-agent`** is typically a **symlink to `chump`** for scripts that still say **`rust-agent`**. Prefer **`./run-discord.sh`** / **`./run-discord-full.sh`** so the right binary is chosen.
