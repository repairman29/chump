# Mabel on Pixel: Performance Spec and Tuning

Performance and capacity for Mabel (Chump + llama.cpp) on Pixel 8 Pro / Termux with Vulkan. Use this to tune for speed, lower latency, or to see if you have room for a larger model.

---

## 1. Current spec (baseline)

| Item | Value | Notes |
|------|--------|------|
| **Device** | Pixel 8 Pro | 12 GB unified RAM, Tensor G3 (Adreno 750–class GPU) |
| **Stack** | Termux, llama.cpp (Vulkan), Chump binary | Single process for bot; llama-server separate |
| **Model** | Qwen 2.5 3B Instruct, Q4_K_M GGUF | ~2 GB file, ~2.1 GB VRAM for weights |
| **Context** | 4096 (`CHUMP_CTX_SIZE`) | KV cache; larger = more RAM, slower first token |
| **GPU layers** | 99 (`CHUMP_GPU_LAYERS`) | Full offload to Vulkan |
| **Server** | llama-server, port 8000 | OpenAI-compatible API |

**Rough memory use (typical):**

- Android OS: 3–5 GB
- llama-server (3B Q4_K_M, ctx 4096, Vulkan): ~3–4 GB (weights + KV cache + Vulkan overhead)
- Chump: ~15–30 MB
- **Total for Mabel:** ~4–5 GB → **~7–8 GB free** on a 12 GB device under normal use

So there is headroom for a larger model or a larger context, as long as you don’t run many other heavy apps at the same time.

---

## 2. Tunables (what you can change)

All of these can be set in `~/chump/.env` on the Pixel (or in `start-companion.sh`). The script reads: `CHUMP_MODEL`, `CHUMP_CTX_SIZE`, `CHUMP_GPU_LAYERS`, `CHUMP_PORT`.

| Variable | Default | Effect | When to change |
|----------|---------|--------|----------------|
| **CHUMP_CTX_SIZE** | 4096 | KV context length | Lower (2048) = less RAM, faster first token; higher (8192) = longer threads, more RAM. |
| **CHUMP_GPU_LAYERS** | 99 | Layers on GPU | 99 = full Vulkan. Lower = more CPU, less VRAM, often slower. |
| **CHUMP_MODEL** | `~/models/qwen2.5-3b-instruct-q4_k_m.gguf` | Model path | Point to 7B or other GGUF to try bigger models. |
| **CHUMP_PORT** | 8000 | Server port | Change only if 8000 is in use. |

llama-server does not expose a separate “batch size” in the same way as some backends; concurrency is mostly “one request at a time” for a single Discord user. So tuning is mainly: **model size**, **context size**, and **GPU layers**.

---

## 3. Optimization options

### 3.1 Reduce latency (faster first reply)

- **Lower context:** e.g. `CHUMP_CTX_SIZE=2048`. Saves RAM and speeds up prefill; shorter conversation history.
- **Keep 3B:** 3B is already one of the faster options; going to 7B will be slower per token and use more RAM.
- **Vulkan:** Already best option on Tensor G3; CPU-only would be much slower (3–5× in typical setups).

### 3.2 Free RAM for other apps or for a bigger model

- **Lower context:** `CHUMP_CTX_SIZE=2048` (or 3072) frees a few hundred MB.
- **Close other apps** so Android doesn’t kill Termux when memory is tight.

### 3.3 Slightly better quality (same device)

- **Try 7B:** e.g. Qwen 2.5 7B Instruct Q4_K_M (~4.5 GB). Fits in ~6 GB with ctx 4096 if you have ~7–8 GB free. Download and set `CHUMP_MODEL` to the 7B GGUF path, then restart.
- **Keep ctx 4096** for 7B if RAM allows; lowering to 2048 also works if you hit OOM.

---

## 4. Bigger models: do we have room?

**Yes, with limits.**

- **7B Q4_K_M (e.g. Qwen 2.5 7B):**  
  - Weights ~4.5 GB, plus KV cache (e.g. 4096) and Vulkan overhead → **~6–7 GB** for llama-server.  
  - With 12 GB total and ~4 GB for Android + Chump, you’re at the edge; **close other apps** and try. If it’s stable, you have room for 7B.

- **Larger (e.g. 14B Q3, ~6 GB weights):**  
  - Would need ~8 GB+ for server; on 12 GB device that’s **tight** and may OOM or get killed. Not recommended unless you’re on a device with more RAM.

**Recommendation:**  
- Stay on **3B** for lowest latency and safest RAM.  
- If you want better quality and have **~7–8 GB free** (and few other apps), try **7B** and watch for OOM or Termux being killed; reduce `CHUMP_CTX_SIZE` if needed.

---

## 5. Quick reference: env for tuning

Add or edit in `~/chump/.env` on the Pixel:

```bash
# Optional: smaller context (faster, less RAM)
# CHUMP_CTX_SIZE=2048

# Optional: 7B model (better quality, more RAM)
# CHUMP_MODEL=$HOME/models/qwen2.5-7b-instruct-q4_k_m.gguf
```

Then restart: `pkill -f 'chump --discord'`; `pkill -f llama-server`; `cd ~/chump && ./start-companion.sh`.

---

## 6. Max Mabel on Pixel (all tools, lean device)

**Goal:** Mabel has every tool and capability that makes sense on the Pixel; the device stays fast. Only leave **unset** the env that is meaningless or dev-only there.

### Do not set (device-irrelevant or dev-only)

| Variable | Why |
|----------|-----|
| **CHUMP_REPO** / **CHUMP_HOME** | No codebase on the phone; avoids giant repo block in the system prompt. |
| **CHUMP_WARM_SERVERS** | Ollama warm-the-ovens — irrelevant on Pixel (you use llama-server). |
| **CHUMP_CURSOR_CLI** | Cursor is not on the Pixel. |
| **CHUMP_PROJECT_MODE** | Would override your custom soul with the Chump dev-buddy soul. |

Optionally omit **CHUMP_GITHUB_REPOS** / **GITHUB_TOKEN** if you don't need GitHub from the device; if you do, set them and Mabel gets GitHub tools.

### Do set (max capabilities)

- **Required:** `DISCORD_TOKEN`, `OPENAI_API_BASE`, `OPENAI_API_KEY`, `OPENAI_MODEL`, `CHUMP_SYSTEM_PROMPT` (e.g. badass soul from [MABEL_FRONTEND.md](MABEL_FRONTEND.md)).
- **For full tool set:**  
  - **TAVILY_API_KEY** — web search; set if you have a key.  
  - **CHUMP_DELEGATE** + worker URL — summarize/extract; set if you have a delegate worker.  
  - **CHUMP_CLI_ALLOWLIST** (and optionally **CHUMP_CLI_BLOCKLIST**) — run_cli; use a sensible allowlist so she can run safe commands.
- **Already available** from `~/chump`: memory, calculator, read_url, task, ego, episode, schedule, memory_brain, notify (sessions DB in ~/chump). No extra env needed for these.
- **Optional:** `CHUMP_CTX_SIZE=4096` (default) or `2048` for slightly faster first token.

### Android: keep the device lean and fast

- **Settings → Developer options** (or **Accessibility**): reduce or turn off **window/transition/animator scale** to reduce UI lag.
- **Settings → Apps**: limit or disable background apps you don't need so more RAM and CPU stay for Termux.
- **Termux → Battery**: set to **Unrestricted** (or "Don't optimize") so Android doesn't kill the bot or sshd in the background.

See also: [Chump Android Companion](ANDROID_COMPANION.md) for deploy and one-time setup.

### Apply on the Pixel (badass soul + lean env)

**Option A — run the script (after deploy):**  
From Termux on the Pixel (or from Mac via SSH):

```bash
# After deploy: script is in ~/chump or ~/storage/downloads/chump
bash ~/chump/apply-mabel-badass-env.sh
# or
bash ~/storage/downloads/chump/apply-mabel-badass-env.sh
```

The script backs up `~/chump/.env`, strips the "do not set" vars, sets `CHUMP_SYSTEM_PROMPT` to the badass soul, and restarts the bot (llama-server is left running).

**Option B — by hand:**  
Edit `~/chump/.env`: remove any lines for `CHUMP_REPO`, `CHUMP_HOME`, `CHUMP_WARM_SERVERS`, `CHUMP_CURSOR_CLI`, `CHUMP_PROJECT_MODE`. Set `CHUMP_SYSTEM_PROMPT` to the badass line from [MABEL_FRONTEND.md](MABEL_FRONTEND.md). Then: `pkill -f 'chump --discord'`; `cd ~/chump && nohup ./start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1 &`.

---

## 7. Measuring (if you want numbers)

- **Token throughput:** In Termux, watch llama-server stdout or logs while Mabel replies; many builds print tokens/sec or you can infer from timestamps.
- **RAM:** `top` or `procrank` (if available) in Termux; or Android Settings → Apps → Termux → Memory.
- **Stability:** If Termux or the bot is killed in the background, try lowering `CHUMP_CTX_SIZE` or switching back to 3B.

See also: [Chump Android Companion](ANDROID_COMPANION.md) (model table, RAM budget, Vulkan build).

---

## 8. System capacity on the Pixel (for additional improvements)

What you have in place on the Pixel and where there’s room to grow:

**Stack**
- **Termux** with persistent **sshd** (port 8022), so you can deploy and run commands from the Mac.
- **llama-server** (llama.cpp + Vulkan) on port 8000, OpenAI-compatible; **Chump** (Mabel) as the Discord bot.
- **Sessions and memory** under `~/chump/sessions` (SQLite, FTS5); logs under `~/chump/logs`.
- **Scripts** in `~/chump` or `~/storage/downloads/chump`: setup-termux-once, setup-llama-on-termux, setup-and-run, start-companion, **apply-mabel-badass-env**; deploy from Mac via ADB or SSH.

**Resource headroom (12 GB Pixel 8 Pro)**
- Typical use: Android ~3–5 GB, llama-server (3B + Vulkan) ~3–4 GB, Chump ~15–30 MB → **~7–8 GB free**.
- So you have capacity for: **7B model** (if you close other apps), **larger context** (e.g. 8192 with 3B), or keeping 3B and using the free RAM for other services (e.g. a small web UI or bridge).

**Levers for improvement**
- **Model:** Switch to 7B (see §4) for better quality; stay on 3B for lowest latency.
- **Context:** `CHUMP_CTX_SIZE` (e.g. 2048 vs 4096) trades RAM and first-token speed for conversation length.
- **Tools:** Set **TAVILY_API_KEY** for web search, **CHUMP_DELEGATE** for summarize/extract, **CHUMP_CLI_ALLOWLIST** for run_cli; see §6.
- **Device:** Reduce animations, limit background apps, Termux battery Unrestricted (§6) so the bot and SSH stay reliable.
- **Future:** Custom chat UI can talk to Mabel via Discord (Option A in [MABEL_FRONTEND.md](MABEL_FRONTEND.md)) or, if you add an HTTP/WebSocket chat API to Chump, directly to the Pixel.
