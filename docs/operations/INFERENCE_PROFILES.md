---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Inference profiles — how we operate Chump

This is the **canonical guide** for choosing and running local inference. Pick **one primary profile per machine** unless you are deliberately A/B testing. Documented defaults here match **`scripts/dev/env-max_m4.sh`**, **`docs/operations/STEADY_RUN.md`**, and **`keep-chump-online.sh`** behavior.

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

Set in **`.env`** so **`serve-vllm-mlx.sh`** and **`scripts/setup/restart-vllm-if-down.sh`** stay aligned:

- **`CHUMP_MAX_CONCURRENT_TURNS=1`** — one Discord/heartbeat turn at a time so **8000** is not overloaded.
- **`CHUMP_MODEL_REQUEST_TIMEOUT_SECS=300`** (optional; default is 300) — long enough for 14B.
- **`VLLM_MAX_NUM_SEQS=1`**, **`VLLM_MAX_TOKENS=4096`**, **`VLLM_CACHE_PERCENT=0.12`** — conservative; raise only after days of stability (see **`docs/operations/STEADY_RUN.md`**).

**Startup order**

1. **Model server:** `./scripts/setup/restart-vllm-if-down.sh` — starts **`./serve-vllm-mlx.sh`** in the background if **8000** is down; logs **`logs/vllm-mlx-8000.log`**.
2. **Wait for readiness (poll only, no second server):** `./scripts/setup/wait-for-vllm.sh` — probes **`/v1/models`** until **HTTP 200** (default **20 min** timeout; raise **`CHUMP_WAIT_VLLM_TIMEOUT_SECS`** for a first-time Hugging Face download). One-liner alternative: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/v1/models` → **200**.
3. **Discord bot (full toolkit):** `./run-discord-full.sh` — ensures restart script ran, builds **release + inprocess-embed**, runs **`./target/release/chump`** (or **`chump`**) **`--discord`**.  
   **Or**, after a manual release build: **`./run-discord.sh`** — prefers release binary (see script).
4. **Web / PWA:** **`./run-web.sh`** — when **`.env`** points at **8000**, it can ensure the model is up before binding (see **`docs/operations/OPERATIONS.md`**).

**Automation (optional)**

- **`./scripts/dev/keep-chump-online.sh`** — if **`OPENAI_API_BASE`** points at **127.0.0.1:8000** or **:8001**, it **skips Ollama** and tends that **vLLM-MLX** port + optionally Discord (**`CHUMP_KEEPALIVE_DISCORD=1`**).
- **launchd** examples: **`scripts/plists/restart-vllm-if-down.plist.example`**, Farmer Brown / roles per **`docs/operations/OPERATIONS.md`**.

### 1b. Maximum quality + performance on **24 GB unified** (e.g. MacBook Air M4)

This is the **strongest** setup the repo standardizes for Apple Silicon when you want **best model quality** and **good real-world throughput**, not Ollama on 11434 (which is simpler but usually slower / less steady for full Chump).

| Layer | Choice |
|-------|--------|
| **Runtime** | **vLLM-MLX** on **8000** only — Metal path; **`serve-vllm-mlx.sh`** stops Ollama so you are not splitting RAM between two servers. |
| **Weights** | Default **`mlx-community/Qwen2.5-14B-Instruct-4bit`** (set **`VLLM_MODEL`** in **`.env`** if you want another MLX tag from the `serve-vllm-mlx.sh` header, e.g. Qwen3 14B, after you confirm it loads). |
| **Chump binary** | **`cargo build --release --features inprocess-embed`** — full tools **without** a separate Python embed server hammering RAM ([`run-discord-full.sh`](../run-discord-full.sh)). |
| **Shell helper** | **`source scripts/dev/env-max_m4.sh`** — points **`OPENAI_*`** at **8000** and sets **`CHUMP_TEST_CONFIG=max_m4`** (mirror those lines in **`.env`** for persistent config). |
| **Concurrency** | **`CHUMP_MAX_CONCURRENT_TURNS=1`** + **`HEARTBEAT_LOCK=1`** — fewer overlapping GPU-heavy turns ([`STEADY_RUN.md`](STEADY_RUN.md)). |
| **vLLM throttles (stable first)** | **`VLLM_MAX_NUM_SEQS=1`**, **`VLLM_MAX_TOKENS=4096`**, **`VLLM_CACHE_PERCENT=0.12`** in **`.env`** so **`serve-vllm-mlx.sh`** / **`restart-vllm-if-down.sh`** stay aligned. |
| **Before long sessions** | **`./scripts/setup/enter-chump-mode.sh`** — frees unified memory ([`GPU_TUNING.md`](GPU_TUNING.md) §1). |

**Copy-paste `.env` core (8000 + 14B + steady throttles):**

```bash
OPENAI_API_BASE=http://127.0.0.1:8000/v1
OPENAI_API_KEY=not-needed
OPENAI_MODEL=mlx-community/Qwen2.5-14B-Instruct-4bit
CHUMP_MAX_CONCURRENT_TURNS=1
HEARTBEAT_LOCK=1
VLLM_MAX_NUM_SEQS=1
VLLM_MAX_TOKENS=4096
VLLM_CACHE_PERCENT=0.12
# Optional: HF_TOKEN=... for faster Hugging Face downloads of the MLX weights
```

**Startup order:** `./scripts/setup/restart-vllm-if-down.sh` → **`./scripts/setup/wait-for-vllm.sh`** (or **`curl`** until **200**) → **`./run-discord-full.sh`** or **`./run-web.sh`**.

**After it is stable for days (more throughput, same model):** raise gradually in **`.env`**, restart vLLM: **`VLLM_MAX_TOKENS=8192`**, **`VLLM_CACHE_PERCENT=0.15`** (then **`0.18`** only if still clean). On any Metal OOM, revert to the block above ([`STEADY_RUN.md`](STEADY_RUN.md)).

**If 14B still OOMs on your workload:** use **§1a** (7B on **8001**) for maximum **tokens/sec**, or set **`VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit`** on **8000** per **`serve-vllm-mlx.sh`** comments — still vLLM-MLX, smaller weights.

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
| Foreground | **`./scripts/setup/serve-vllm-mlx-8001.sh`** (defaults: **7B**, port **8001**, same throttling flags as **`serve-vllm-mlx.sh`**) |
| Background (cron / recovery) | **`./scripts/setup/restart-vllm-8001-if-down.sh`** — logs **`logs/vllm-mlx-8001.log`** |

**Chump entrypoints:** **`./run-web.sh`**, **`./run-discord-full.sh`**, and **`keep-chump-online`** read **`OPENAI_API_BASE`** via **`scripts/setup/openai-base-local-mlx-port.sh`** and will run **`restart-vllm-8001-if-down.sh`** when the base is **8001**, same pattern as **8000**.

**Ollama vs MLX:** Starting MLX via **`serve-vllm-mlx.sh`**, **`serve-vllm-mlx-8001.sh`**, **`restart-vllm-if-down.sh`**, **`restart-vllm-8001-if-down.sh`**, **`run-web.sh`** (when `.env` points at local **8000/8001**), **`run-discord-full.sh`**, or **`keep-chump-online`** (local MLX mode) runs **`scripts/setup/stop-ollama-if-running.sh`** first so **Ollama is not left running** beside vLLM-MLX on the same GPU.

**Optional:** Run **14B on 8000** and **7B on 8001** in two terminals for A/B; point **`.env`** at only one base at a time for a given Chump process.

**One-shot .env (repo root):** `python3 scripts/setup/apply-mlx-8001-env.py` — appends / replaces the three **`OPENAI_*`** lines under a marker (other keys untouched).

**Operational rules**

- **Do not** point **`OPENAI_API_BASE`** at random ports — use **8000** (vLLM-MLX), **11434** (Ollama), or **8001** where documented; **`scripts/ci/check-heartbeat-preflight.sh`** enforces this for heartbeats.
- **One** inference URL in **`.env`** for normal operation; change it only when switching profiles (see §3).
- After **`.env`** changes, **restart** the Discord (and web) processes.

### 1c. Newer models for **multi-step tools** (try after Qwen2.5-14B-Instruct)

**Goal:** Same **vLLM-MLX :8000** stack, different Hugging Face weights — set **`VLLM_MODEL`** and **`OPENAI_MODEL`** to the **same** repo id, restart **`./scripts/setup/restart-vllm-if-down.sh`**, then run one **`just dogfood-t1-1-probe …`** or a short PWA chat to verify tool JSON shape.

| Model id (mlx-community) | Role | Notes |
|--------------------------|------|--------|
| **`mlx-community/Qwen2.5-14B-Instruct-4bit`** | Default | Best-tested with Chump; strong instruct + tools. |
| **`mlx-community/Qwen3-14B-4bit`** | Newer Qwen3 line | Listed in **`serve-vllm-mlx.sh`** header; **text-generation** on Hugging Face. Try this first when “2.5 isn’t enough” — validate tool calling in practice (may differ from 2.5 instruct tuning). |
| **`mlx-community/Qwen3.5-9B-OptiQ-4bit`** | **Qwen3.5 9B** (text-gen, Metal) | **Preferred 9B for Chump + vLLM-MLX:** `pipeline_tag: text-generation`, OptiQ mixed-precision (~5.7GB on disk per model card). Avoid **`Qwen3.5-9B-MLX-4bit`** / **`Qwen3.5-9B-4bit`** for chat — those are **image-text-to-text** / VLM conversions. After `vllm-mlx serve` loads, set **`OPENAI_MODEL`** to this **same** id. |
| **`mlx-community/Qwen3-14B-3bit`** | Same family, less RAM | If **4bit** pushes Metal OOM on **24 GB** unified with desktop apps open. |
| **`mlx-community/Qwen2.5-14B-Instruct-3bit`** | Lighter 2.5 instruct | Same instruct chat template family as default; less VRAM than 4bit. |
| **`mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit-dwq-v2`** | MoE **coder** | Strong for code edits; **30B-class** — may be **tight** on **24 GB** with KV; try only after shed-load; confirm **`vllm-mlx serve`** loads it. |

**Caution — Qwen3.5 MLX repos:** Many **`mlx-community/Qwen3.5-*-MLX-4bit`** builds are tagged **image-text-to-text** / **mlx-vlm** conversions. For **plain Chump chat + tools**, use **`pipeline_tag: text-generation`** repos (e.g. **`Qwen3.5-9B-OptiQ-4bit`** in the table above) until you confirm **`vllm-mlx serve`** accepts a specific 3.5 build.

**Ollama (faster A/B than re-downloading MLX):** Use **`ollama pull`** tags such as **`qwen3:8b`**, **`qwen3:4b`**, **`qwen2.5:14b`** with **`OPENAI_API_BASE=http://127.0.0.1:11434/v1`** — good for **dogfood / probe matrices** ([`docs/operations/MODEL_TESTING_TAIL.md`](MODEL_TESTING_TAIL.md), **`scripts/eval/dogfood-t1-1-probe.sh`**). See also [`docs/OLLAMA_SPEED.md`](OLLAMA_SPEED.md) §6 for **24 GB** Air tuning.

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

**Note:** **`keep-chump-online`** behaves differently when **`.env`** points at **11434** vs **8000** / **8001** (Ollama vs local vLLM-MLX). See **`scripts/dev/keep-chump-online.sh`**.

---

## 2b. In-process **mistral.rs** (optional Cargo feature)

**What it is:** The **`mistralrs`** crate runs a Hugging Face text model **inside the Chump process** (no separate `vllm-mlx` / Ollama HTTP server). Same agent loop and tools as the HTTP providers.

**Ops / UI contract:** When **`CHUMP_INFERENCE_BACKEND=mistralrs`** and **`CHUMP_MISTRALRS_MODEL`** are set, **`GET /api/stack-status`** and **`GET /health`** treat primary inference as in-process (see [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) — `inference.primary_backend`, `openai_http_sidecar`). PWA stack pills and Providers follow that contract so a dead optional HTTP sidecar does not read as “no model.”

**Precedence vs provider cascade:** With a build that includes **`mistralrs-infer`** (or **`mistralrs-metal`**), when mistral env is set as above, **completions use in-process mistral.rs first** — even if **`CHUMP_CASCADE_ENABLED=1`** and **`OPENAI_API_BASE`** (or cascade slots) are configured. The HTTP cascade is skipped for the primary LLM path in that case. To use the free-tier cascade as primary again, unset **`CHUMP_INFERENCE_BACKEND`** / **`CHUMP_MISTRALRS_MODEL`** (or point inference at HTTP only). See [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md). For a one-shot mistral-primary dev session, **`scripts/dev/run-web-mistralrs-infer.sh`** unsets **`OPENAI_API_BASE`** (optional convenience).

**One primary local LLM (avoid MLX + Ollama + mistral competing):** The Rust binary does not spawn Ollama or vLLM, but **shell entrypoints** used to start vLLM-MLX whenever **`OPENAI_API_BASE`** pointed at **:8000** / **:8001**, even if mistral was also selected — wasting unified memory and thermals. Now **`scripts/setup/inference-primary-mistralrs.sh`** (exit **0** when env matches **`chump_inference_backend_mistralrs_env`**) gates **`run-web.sh`**, **`run-discord-full.sh`**, and **`keep-chump-online.sh`**: they **skip** auto-start of vLLM-MLX and (for keep-chump-online) **do not** start Ollama when mistral is primary. For mistral-only operation, **unset `OPENAI_API_BASE`** in **`.env`** (or use **`scripts/dev/run-web-mistralrs-infer.sh`**), stop stray **`ollama serve`** / **`vllm-mlx`** manually if still running, and leave **`CHUMP_CASCADE_ENABLED=0`** unless you want optional cloud slots. Note: **`chump --warm-probe`** and some heartbeat helpers still hit cascade HTTP endpoints when cascade is enabled — they do not load a second in-process model, but they can generate cloud traffic.

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
| **`mistralrs-metal`** | Apple Silicon GPU | Full **Xcode** or **Command Line Tools** that ship the Metal compiler; **`xcrun metal --version`** must succeed (not only `clang`). Enables Metal path inside `mistralrs`. |

If **`cargo build`** fails with **`xcrun: unable to find utility "metal"`**, install **full Xcode** from the App Store (or a CLT bundle that includes **`metal`**) and verify with **`xcrun metal --version`**; otherwise use **`mistralrs-infer`** (CPU-only) for that machine.

```bash
# CPU / portable (CI-friendly; slow on large models)
cargo build --release --features mistralrs-infer

# Apple Silicon GPU
cargo build --release --features mistralrs-metal
```

**`CHUMP_MISTRALRS_FORCE_CPU=1`** forces CPU even when the binary was built with **`mistralrs-metal`** (useful to rule out Metal/driver issues).

### 2b.3 Environment, `HF_TOKEN`, and first-run download

**`.env` for in-process primary:** You may keep **`OPENAI_API_BASE`** for an optional HTTP sidecar (embeddings, tools); completions still use mistral when backend + model env are set (see precedence above). To avoid confusion, you can omit **`OPENAI_API_BASE`** or use **`scripts/dev/run-web-mistralrs-infer.sh`** for a clean mistral-only dev session.

```bash
CHUMP_INFERENCE_BACKEND=mistralrs
CHUMP_MISTRALRS_MODEL=Qwen/Qwen3-4B
# Optional: 2–8 (default 8) — ISQ auto-quantization target bits (mistral.rs picks platform types)
# CHUMP_MISTRALRS_ISQ_BITS=8
# Optional: HF revision; prefix cache (`off`/`none`/`disable` to disable); MoQE; PagedAttention; throughput logging
# CHUMP_MISTRALRS_HF_REVISION=
# CHUMP_MISTRALRS_PREFIX_CACHE_N=16
# CHUMP_MISTRALRS_MOQE=0
# CHUMP_MISTRALRS_PAGED_ATTN=0
# CHUMP_MISTRALRS_THROUGHPUT_LOGGING=0
# CHUMP_MISTRALRS_FORCE_CPU=0
# CHUMP_MISTRALRS_LOGGING=1
OPENAI_MODEL=Qwen/Qwen3-4B
```

**`HF_TOKEN`** (in **`.env`**, same as vLLM/MLX): Hugging Face token for **first-time weight download** and to avoid **rate limits** on busy networks. Some repos are **gated** — without a token you may see **401** or empty errors during load. Set **`HF_TOKEN=hf_...`** (see **`.env.example`**).

**First chat after start:** Weights load on **first** completion path (Discord / PWA / CLI). Expect **minutes** before the first token on large models; this is not necessarily an HTTP failure (see §2b.5).

**Higher-performance agent path (metrics, HTTP vs in-process A/B, `mistralrs tune` → env):** [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) · `scripts/ci/mistralrs-inference-ab-smoke.sh` · `source ./scripts/dev/env-mistralrs-power.sh` · **`run-web-mistralrs-infer.sh`** enables **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`** by default for PWA SSE.

### 2b.4 Memory, ISQ, and model size

- Larger models need more **unified RAM** (Mac) or **RAM** (CPU). If the process is **killed** or the machine **locks**, try a **smaller** `CHUMP_MISTRALRS_MODEL`, lower **`CHUMP_MISTRALRS_ISQ_BITS`** (e.g. **4** or **3**), or switch to **§1 / §2** HTTP with a smaller served model.
- **Advanced (mistralrs 0.8.1):** **`CHUMP_MISTRALRS_HF_REVISION`** pins the Hugging Face revision. **`CHUMP_MISTRALRS_PREFIX_CACHE_N`** sets prefix-cache slot count, or **`off`** / **`none`** / **`disable`** to disable. **`CHUMP_MISTRALRS_MOQE=1`** enables mixture-of-quantized-experts ISQ organization. **`CHUMP_MISTRALRS_PAGED_ATTN=1`** enables PagedAttention when the platform supports it. **`CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1`** enables runner throughput logs. Full table: [MISTRALRS.md](MISTRALRS.md).
- **Token streaming (in-process mistral):** **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`** (or `true`) enables chunk streaming inside [`StreamingProvider`](../src/streaming_provider.rs). **PWA / RPC:** SSE **`text_delta`** events; on success the server may omit **`text_complete`**. **Discord:** only the **tool-approval** branch uses **`StreamingProvider`**; the bot still shows the **final** reply from **`turn_complete`** (no live partials in chat). **Standard** Discord turns (no approval tools) do not use **`StreamingProvider`**. Does **not** apply to HTTP OpenAI providers. See [rfcs/RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) and **WP-1.6** in [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md).
- **Structured assistant text (opt-in, tool-free turns only):** **`CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA`** = path to a JSON file whose root is a JSON Schema; loaded once per process. Applied only when the completion has **no tools** (see [ADR-002](ADR-002-mistralrs-structured-output-spike.md), [MISTRALRS.md](MISTRALRS.md)).
- Tuning context for **Metal OOM** and load shedding overlaps **[GPU_TUNING.md](GPU_TUNING.md)** and **[INFERENCE_STABILITY.md](INFERENCE_STABILITY.md)** (degraded mode is still about *recovering* inference — here the “server” is in-process).

### 2b.5 Failure modes (quick fixes)

| Symptom | Likely cause | What to try |
|---------|----------------|------------|
| Build error around Metal / `mistralrs-metal` | Xcode / CLT without **`metal`** tool, or wrong machine | **`xcrun metal --version`** must work for **`mistralrs-metal`**. If you see **`xcrun: unable to find utility "metal"`**, install full **Xcode** (or CLT that includes Metal), or build with **`mistralrs-infer`** only; on **non-Apple** targets use **`mistralrs-infer`**. |
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

### 2b.8 Upstream **`mistralrs tune`** (hardware-aware ISQ hints)

**What it is:** The upstream **mistral.rs CLI** (not the `mistralrs` library linked inside Chump) can **benchmark your machine** and print **quantization / memory / quality trade-offs** for a Hugging Face model, or **emit a TOML** for `mistralrs from-config`. This answers “what ISQ width fits my GPU/RAM?” faster than guesswork.

**Install the CLI:** Use the official **mistral.rs** install path so the `mistralrs` binary is on your `PATH` — see the [mistral.rs README — Installation](https://github.com/EricLBuehler/mistral.rs#installation) (prebuilt releases, `cargo install`, or package managers). You do **not** need Chump rebuilt; this is a separate tool.

**Common commands** (model id should match **`CHUMP_MISTRALRS_MODEL`** when comparing to in-process Chump):

```bash
# Balanced recommendations (default profile)
mistralrs tune -m Qwen/Qwen3-4B

# Emphasize quality or speed
mistralrs tune -m Qwen/Qwen3-4B --profile quality
mistralrs tune -m Qwen/Qwen3-4B --profile fast

# Machine-readable output
mistralrs tune -m Qwen/Qwen3-4B --json

# Write a TOML you can run with the upstream CLI (not consumed by Chump today)
mistralrs tune -m Qwen/Qwen3-4B --emit-config ./mistralrs-tuned.toml
mistralrs from-config --file ./mistralrs-tuned.toml
```

**Map recommendations to Chump (in-process):** Chump only exposes **auto-ISQ by bit target** via **`CHUMP_MISTRALRS_ISQ_BITS`** (**2–8**); see [MISTRALRS.md](MISTRALRS.md). Use `tune` output to pick a **bit width** that fits your RAM/VRAM, then set **`CHUMP_MISTRALRS_ISQ_BITS`** accordingly. Per-layer topology or device mapping from `tune` is **not** wired into Chump’s builder; for that level of control use **`mistralrs serve`** or **`from-config`** and point Chump at **`OPENAI_API_BASE`** (§2b.7).

**Auth:** Use **`HF_TOKEN`** (or upstream **`mistralrs login`**) for gated models and reliable downloads — same as §2b.3.

**Further reading:** Upstream [CLI reference — `tune`](https://github.com/EricLBuehler/mistral.rs/blob/master/docs/CLI.md), [TOML config](https://github.com/EricLBuehler/mistral.rs/blob/master/docs/CLI_CONFIG.md). Optional diagnostics: **`mistralrs doctor`**.

**Chump benchmark scripts:** [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) — `scripts/eval/bench-mistralrs-tune.sh` (upstream `tune`) and `scripts/eval/bench-mistralrs-chump.sh` (CSV wall-time matrix for in-process `chump`).

---

## 3. Switching profiles (checklist)

1. **Stop** the Discord bot: **`./scripts/setup/stop-chump-discord.sh`** or **`pkill -f 'chump.*--discord'`** / **`pkill -f 'rust-agent.*--discord'`**.
2. Edit **`.env`**: set **`OPENAI_API_BASE`**, **`OPENAI_MODEL`**, **`OPENAI_API_KEY`** per §1 or §2 — **or** §2b (**`CHUMP_INFERENCE_BACKEND=mistralrs`**, **`CHUMP_MISTRALRS_MODEL`**). You may omit **`OPENAI_API_BASE`** or leave cascade vars on; with §2b + a mistralrs build, **completions** use mistral first (see §2b precedence).
3. **Primary (8000):** run **`./scripts/setup/restart-vllm-if-down.sh`**. **Lite MLX (8001):** run **`./scripts/setup/restart-vllm-8001-if-down.sh`** or **`./scripts/setup/serve-vllm-mlx-8001.sh`**. **Ollama profile:** ensure **`ollama serve`** and model pulled. **mistral.rs in-process:** build with **`mistralrs-infer`** (or **`mistralrs-metal`** on Mac).
4. **Primary full tools:** `cargo build --release --features inprocess-embed` then **`./run-discord.sh`** or **`./run-discord-full.sh`**.
5. **Ollama quick:** **`./run-discord-ollama.sh`**.

---

## 4. Testing configs without editing `.env` long-term

- **`source scripts/dev/env-max_m4.sh`** — exports **8000** + MLX model + **`CHUMP_TEST_CONFIG=max_m4`** for a shell session.
- **`source scripts/dev/env-default.sh`** — Ollama-style defaults for tests (see **`scripts/ci/run-tests-with-config.sh`**).

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

## 6. Advanced profile: SGLang (research / high-throughput)

**What it is:** [SGLang](https://github.com/sgl-project/sglang) is an inference framework with RadixAttention (shared prefix caching across requests) and structured decoding. OpenAI-compatible API on port 30000 by default.

**When to use:**

- **Heavy concurrent workload** — fleet deployments where multiple Chump instances share a model server. RadixAttention caches common prefixes (system prompt, tool schemas) across requests, cutting TTFT significantly.
- **Structured output** — if you rely heavily on tool calling with JSON schema constraints, SGLang's `regex=`, `json_schema=` decoding is faster than trial-and-error retry.
- **Research / benchmarking** — published benchmarks use it; useful for head-to-head comparisons.

**When NOT to use:**

- Single-user laptop deployment — Ollama/vLLM-MLX is simpler and competitive.
- macOS — SGLang doesn't have a Metal backend as of April 2026; Linux + NVIDIA only.

**Setup:**

```bash
pip install "sglang[all]"
python -m sglang.launch_server \
  --model-path Qwen/Qwen2.5-14B-Instruct \
  --port 30000 \
  --host 127.0.0.1
```

Then in `.env`:

```bash
OPENAI_API_BASE=http://127.0.0.1:30000/v1
OPENAI_MODEL=Qwen/Qwen2.5-14B-Instruct
OPENAI_API_KEY=not-needed
```

Chump's OpenAI-compatible client path works without modification — SGLang exposes the same API.

**Known integration gaps (V2 work):**

- Chump doesn't yet pass `regex=` / `json_schema=` extensions when calling tool-enabled endpoints. For now, SGLang treats the requests as standard completions. A future refactor could surface these structured-decoding hints to the provider cascade (see Sprint D4 in docs/strategy/NEXT_GEN_COMPETITIVE_INTEL.md).
- RadixAttention benefits require keeping the system prompt byte-stable across turns. Chump's dynamic context assembly (ego state, regime summaries) invalidates the prefix cache on every turn. Pin the system prompt with `CHUMP_PROMPT_STABILITY=1` (future feature) to get full benefit.

**Strategic note:** SGLang is used by several of the reference projects in [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md). Adoption as an optional profile gives Chump parity without committing to it as the default — Ollama and vLLM-MLX remain the recommended paths.

---

## 7. Binary and package name

The Cargo package and default binary are both **`chump`**; the release artifact is **`target/release/chump`**. Older docs and scripts may still mention **`rust-agent`** for process patterns on machines that have not rebuilt yet. Prefer **`./run-discord.sh`** / **`./run-discord-full.sh`** / **`./run-web.sh`** so the correct binary is chosen.
