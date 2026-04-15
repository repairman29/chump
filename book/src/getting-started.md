# External golden path (minimal first success)

**Goal:** From a cold clone, get **inference + one surface + a health check** without Discord, fleet, or `chump-brain/`. Time target: **under 30 minutes** on a fast connection (Rust + model pull dominate).

**Discord:** Optional. This path uses the **web PWA** as the default first surface; add Discord later if you want. Fleet (Pixel/Mabel) is an **upsell** after N1-style success—see [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) Horizon 2.

**Not in this path:** Mabel/Pixel, provider cascade, ship heartbeat, launchd roles, Cursor CLI. See [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) Horizon 2+ and [SETUP_QUICK.md](SETUP_QUICK.md) for the full stack.

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| **Rust** | Stable toolchain (`rustup`, `cargo`). Edition 2021 per `Cargo.toml`. |
| **Git** | Clone this repository. |
| **Ollama** | [ollama.com](https://ollama.com) — local OpenAI-compatible API on `http://localhost:11434`. |
| **OS** | macOS or Linux primary; Windows may work via WSL (not regularly tested here). |

### Daily driver profile (recommended first stack)

Keep **one** inference profile until you intentionally switch (see [.env.example](../.env.example) header):

| Variable | Typical value |
|----------|----------------|
| `OPENAI_API_BASE` | `http://localhost:11434/v1` (Ollama) |
| `OPENAI_API_KEY` | `ollama` |
| `OPENAI_MODEL` | e.g. `qwen2.5:14b` (must be pulled: `ollama pull …`) |

After **`./run-web.sh`** or **`chump --web`** is listening, run **`./scripts/chump-preflight.sh`** (or **`chump --preflight`**) to verify **`/api/health`**, **`/api/stack-status`**, **`tool_policy`**, and local **`/v1/models`** reachability. See [OPERATIONS.md](OPERATIONS.md) **Preflight**.

---

## Steps

### 1. Clone and enter the repo

```bash
git clone <your-fork-or-upstream-url> chump
cd chump
```

### 2. Create a minimal `.env`

```bash
./scripts/setup-local.sh
```

Then edit `.env`:

- For **web or CLI only**, **comment out** `DISCORD_TOKEN` or set it empty so the config summary does not treat Discord as configured (see [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) if using the stock placeholder).
- You do **not** need `TAVILY_API_KEY`, `GITHUB_TOKEN`, or cascade keys for this path.

**Minimal variables for Ollama (can also rely on `run-local.sh` defaults):**

```bash
OPENAI_API_BASE=http://localhost:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:14b
```

**Keep your real `.env` aligned with one stack:** If you also set Hugging Face model ids, vLLM bases, or `CHUMP_INFERENCE_BACKEND=mistralrs`, Chump may still talk to Ollama with the wrong model name. For Week 1–2, use **only** the three lines above for `OPENAI_*` and leave mistral / MLX / cascade lines commented until you need them (see [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)). [`.env.example`](../.env.example) starts with the same Ollama block.

**One-shot overrides (optional):** If `.env` still points at another profile but you want to force this path for a single command:

| Variable | When to use |
|----------|-------------|
| `CHUMP_GOLDEN_PATH_OLLAMA=1` | After sourcing `.env`, forces `OPENAI_API_BASE`, `OPENAI_API_KEY`, and `OPENAI_MODEL` to the Ollama values above for **that process only**. |
| `CHUMP_USE_RELEASE=1` | Makes `./run-local.sh` run `cargo run --release --bin chump` (after `cargo build --release --bin chump`). |

Example: `CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --check-config`

### 3. Start Ollama and pull a model

**Recommended on macOS (Homebrew Ollama):** run the daemon under `launchd` so it survives crashes and restarts quickly:

```bash
brew services start ollama
ollama pull qwen2.5:14b
```

After `killall ollama`, `GET http://127.0.0.1:11434/api/tags` should return **200** again within about **10 seconds** (typical respawn a few seconds). Repeat anytime: [`scripts/verify-ollama-respawn.sh`](../scripts/verify-ollama-respawn.sh). **Alternative:** [ChumpMenu](../ChumpMenu/README.md) can start/stop Ollama from the menu bar if you use the menu app daily. Avoid relying on a one-off `nohup ollama serve` in a shell profile unless you accept restarts when that shell exits.

**Manual / dev:** `ollama serve` in a terminal is fine for a session; use another terminal for `ollama pull …`.

### 4. Build (first time)

```bash
cargo build
```

Release is optional for trying the app: `cargo build --release` for production-like latency.

### 5. Verify health (web path — **recommended** for external users)

Start the web server (PWA + API):

```bash
./run-web.sh
# or: ./run-local.sh -- --web --port 3000
```

Check JSON health:

```bash
curl -s http://127.0.0.1:3000/api/health | head -c 500
```

You should see JSON with status fields (model, version, etc.). **Note:** This is **`GET /api/health`** on the **web port** (default 3000). A separate sidecar **`GET /health`** exists only when `CHUMP_HEALTH_PORT` is set (typically with Discord); do not confuse the two.

Open the UI: **http://127.0.0.1:3000** — use the PWA chat if the model is up.

### 6. Optional: CLI one-shot (no browser)

```bash
./run-local.sh -- --chump "Reply in one sentence: what is 2+2?"
```

Expect a short model reply on stdout. Uses the same Ollama env defaults as `run-local.sh` (and strips a stray `--` before `cargo run` so `--check-config` / `--chump` are parsed correctly).

**Latency:** The first `--chump` run after Ollama starts may take **minutes** on a 14B model (load into GPU/RAM). A **second** run with the same model is usually much faster but may still be **tens of seconds** on 14B Apple Silicon depending on load and keep-alive. If warm runs stay very slow, treat it as a performance follow-up (model size, `OLLAMA_KEEP_ALIVE`, MLX/vLLM profile, etc.).

### 7. Optional: Discord

Requires a real bot token and intents — [DISCORD_CONFIG.md](DISCORD_CONFIG.md), [SETUP_QUICK.md](SETUP_QUICK.md), `./scripts/check-discord-preflight.sh`, then `./run-discord-ollama.sh` or `./run-discord.sh`.

---

## Advanced (defer until golden path works)

| Topic | Doc |
|--------|-----|
| vLLM-MLX on port 8000 | [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md), [STEADY_RUN.md](STEADY_RUN.md) |
| Brain wiki + `memory_brain` | [CHUMP_BRAIN.md](CHUMP_BRAIN.md) |
| Fleet / Mabel / Pixel | [ANDROID_COMPANION.md](ANDROID_COMPANION.md), [FLEET_ROLES.md](FLEET_ROLES.md) |
| Provider cascade + privacy | [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) |
| Tool approval / risk | [TOOL_APPROVAL.md](TOOL_APPROVAL.md) |
| Disk / archives | [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) |

---

## Troubleshooting (common)

| Symptom | Check |
|---------|--------|
| `connection refused` on chat | Ollama running? `curl -s http://127.0.0.1:11434/api/tags` |
| Web serves blank or 404 static | `CHUMP_HOME` / repo root so `web/` exists; see [run-web.sh](../run-web.sh) |
| `cargo` errors | `rustc --version`; run `rustup update` |
| Config warnings on stderr | Expected if Discord/brain/tavily unset; see [config_validation.rs](../src/config_validation.rs) |

---

## Next: H1 wedge (task API + optional autonomy)

After §5–6 succeed, optionally run **[WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md)** (`./scripts/wedge-h1-smoke.sh`; no Discord) and **[WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md)** for pilot SQL.

---

## Automated smoke (CI / maintainers)

From repo root (does not start Ollama or the web server):

```bash
./scripts/verify-external-golden-path.sh
```

Runs `cargo build` and checks that golden-path files exist. Used in **GitHub Actions** after `cargo test`.

### Timing regression (Wave 3 / W3.4)

To record how long **cargo build** (and optionally **GET /api/health**) take for cold-start tracking:

```bash
./scripts/golden-path-timing.sh
GOLDEN_TIMING_HIT_HEALTH=1 ./scripts/golden-path-timing.sh   # web must already be up
```

Logs append to **`logs/golden-path-timing-YYYY-MM-DD.jsonl`**. If **`cargo build`** exceeds **`GOLDEN_MAX_CARGO_BUILD_SEC`** (default 900), the script exits **1** and prints a suggested **`[COS]`** task line. See [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) wave W3.4.

**CI:** GitHub Actions runs this after `verify-external-golden-path.sh` with **`GOLDEN_MAX_CARGO_BUILD_SEC=1800`** and uploads **`logs/golden-path-timing-*.jsonl`** as a workflow artifact (see `.github/workflows/ci.yml`).

## Related

- [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) — multi-angle review and **launch gate** checklist  
- [DOSSIER.md](DOSSIER.md) — full product/architecture narrative  
- [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) — template for timed cold-clone tests  
