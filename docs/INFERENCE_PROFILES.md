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

## 2b. In-process **mistral.rs** (optional Cargo feature)

**What it is:** The **`mistralrs`** crate runs a Hugging Face text model **inside the Chump process** (no separate `vllm-mlx` / Ollama HTTP server). Same agent loop and tools as the HTTP providers.

**Ops / UI contract:** When **`CHUMP_INFERENCE_BACKEND=mistralrs`** and **`CHUMP_MISTRALRS_MODEL`** are set, **`GET /api/stack-status`** and **`GET /health`** treat primary inference as in-process (see [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) — `inference.primary_backend`, `openai_http_sidecar`). PWA stack pills and Providers follow that contract so a dead optional HTTP sidecar does not read as “no model.”

### 2b.1 When to use in-process vs HTTP

| Goal | Prefer |
|------|--------|
| Steady Mac production, Farmer Brown / **`restart-vllm-if-down`**, full team alignment | **§1 vLLM-MLX :8000** (or §1a **:8001**) |
| Fastest setup, smallest moving parts | **§2 Ollama :11434** |
| Single Rust process, no Python MLX server, experiments with ISQ / native stack | **§2b in-process mistral.rs** (this section) |
| Rust inference but **isolate** crashes / GPU from the agent | **HTTP sidecar:** upstream **`mistralrs serve`** or **B** in [rfcs/RFC-inference-backends.md](rfcs/RFC-inference-backends.md) — point **`OPENAI_API_BASE`** at localhost like any OpenAI server |

**Default production on Mac** remains **§1** unless you explicitly choose §2b for the reasons above.

### 2b.2 Build: Metal vs CPU

| Feature | Hardware | Prerequisites |
|---------|----------|----------------|
| **`mistralrs-infer`** | CPU (portable) | No Metal; largest models are slow and RAM-heavy. Good for CI, smoke tests, small models. |
| **`mistralrs-metal`** | Apple Silicon GPU | Full **Xcode Command Line Tools**; **`xcrun metal`** must work. Enables Metal path inside `mistralrs`. |

```bash
# CPU / portable (CI-friendly; slow on large models)
cargo build --release --features mistralrs-infer

# Apple Silicon GPU
cargo build --release --features mistralrs-metal
```

**`CHUMP_MISTRALRS_FORCE_CPU=1`** forces CPU even when the binary was built with **`mistralrs-metal`** (useful to rule out Metal/driver issues).

### 2b.3 Environment, `HF_TOKEN`, and first-run download

**`.env` for in-process primary (omit `OPENAI_API_BASE` unless you also want a sidecar for embeddings/cascade — see stack-status `openai_http_sidecar`):**

```bash
CHUMP_INFERENCE_BACKEND=mistralrs
CHUMP_MISTRALRS_MODEL=Qwen/Qwen3-4B
# Optional: 4 or 8 (default 8) — ISQ auto-quantization bit width (memory vs quality)
# CHUMP_MISTRALRS_ISQ_BITS=8
# CHUMP_MISTRALRS_FORCE_CPU=0
# CHUMP_MISTRALRS_LOGGING=1
OPENAI_MODEL=Qwen/Qwen3-4B
```

**`HF_TOKEN`** (in **`.env`**, same as vLLM/MLX): Hugging Face token for **first-time weight download** and to avoid **rate limits** on busy networks. Some repos are **gated** — without a token you may see **401** or empty errors during load. Set **`HF_TOKEN=hf_...`** (see **`.env.example`**).

**First chat after start:** Weights load on **first** completion path (Discord / PWA / CLI). Expect **minutes** before the first token on large models; this is not necessarily an HTTP failure (see §2b.5).

### 2b.4 Memory, ISQ, and model size

- Larger models need more **unified RAM** (Mac) or **RAM** (CPU). If the process is **killed** or the machine **locks**, try a **smaller** `CHUMP_MISTRALRS_MODEL`, lower **`CHUMP_MISTRALRS_ISQ_BITS`** (e.g. **4**), or switch to **§1 / §2** HTTP with a smaller served model.
- Tuning context for **Metal OOM** and load shedding overlaps **[GPU_TUNING.md](GPU_TUNING.md)** and **[INFERENCE_STABILITY.md](INFERENCE_STABILITY.md)** (degraded mode is still about *recovering* inference — here the “server” is in-process).

### 2b.5 Failure modes (quick fixes)

| Symptom | Likely cause | What to try |
|---------|----------------|------------|
| Build error around Metal / `mistralrs-metal` | Xcode CLI missing or wrong machine | Use **`mistralrs-infer`** only, or install Xcode CLT; on **non-Apple** targets use **`mistralrs-infer`**. |
| First request hangs then OOM / kill | Model too large for RAM | Smaller model, **`CHUMP_MISTRALRS_ISQ_BITS=4`**, or HTTP profile §1/§2. |
| Download / auth errors at load | HF rate limit or gated repo | Set **`HF_TOKEN`**; verify model id spelling. |
| “No model” in UI but env looks right | Built **without** `mistralrs-infer` | Rebuild with **`--features mistralrs-infer`** (or **`mistralrs-metal`**). Env alone does not link the crate. |
| PWA shows LLM off while mistral works | Fixed in **WP-1.2** — ensure **`CHUMP_MISTRALRS_MODEL`** non-empty and **`CHUMP_INFERENCE_BACKEND=mistralrs`**; refresh stack status. |

### 2b.6 Pixel / Android (Termux) constraints

**In-process mistral.rs is not the supported Pixel path.** **`mistralrs-metal`** is **Apple Metal** only. The documented **Mabel** setup uses **llama-server** (llama.cpp + Vulkan) with **`OPENAI_API_BASE`** pointing at **127.0.0.1:8000** — see **[ANDROID_COMPANION.md](ANDROID_COMPANION.md)** and **[INFERENCE_MESH.md](INFERENCE_MESH.md)**.

Cross-compiling **`mistralrs-infer`** for Android is **out of scope** for this runbook; use **HTTP** OpenAI-compatible inference on the device or remote.

### 2b.7 Alternative: `mistralrs serve` (HTTP, no Chump feature rebuild)

Run upstream **`mistralrs serve`** (OpenAI-compatible HTTP) and set **`OPENAI_API_BASE`** / **`OPENAI_MODEL`** like §1/§2. Chump’s HTTP provider path and Farmer Brown scripts apply unchanged.

**Tools:** In-process mistral.rs uses the same **Chump-registered** tools as HTTP providers (see [rfcs/RFC-wp13-mistralrs-mcp-tools.md](rfcs/RFC-wp13-mistralrs-mcp-tools.md) — no mistral.rs MCP client for discovery).

---

## 3. Switching profiles (checklist)

1. **Stop** the Discord bot: **`./scripts/stop-chump-discord.sh`** or **`pkill -f 'chump.*--discord'`** / **`pkill -f 'rust-agent.*--discord'`**.
2. Edit **`.env`**: set **`OPENAI_API_BASE`**, **`OPENAI_MODEL`**, **`OPENAI_API_KEY`** per §1 or §2 — **or** §2b (**`CHUMP_INFERENCE_BACKEND=mistralrs`**, **`CHUMP_MISTRALRS_MODEL`**, omit **`OPENAI_API_BASE`**).
3. **Primary (8000):** run **`./scripts/restart-vllm-if-down.sh`**. **Lite MLX (8001):** run **`./scripts/restart-vllm-8001-if-down.sh`** or **`./scripts/serve-vllm-mlx-8001.sh`**. **Ollama profile:** ensure **`ollama serve`** and model pulled. **mistral.rs in-process:** build with **`mistralrs-infer`** (or **`mistralrs-metal`** on Mac).
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
