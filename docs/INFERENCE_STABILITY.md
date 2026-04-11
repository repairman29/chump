# Local inference stability (Mac)

Operational playbook when **vLLM-MLX (port 8000)** or **Ollama (11434)** crashes, OOMs, or leaves the Discord bot saying *Model server isn't responding*.

## Quick triage

1. **Farmer Brown / Sentinel** — Check `logs/sentinel-alert.txt` and `logs/farmer-brown.log` for `Model (8000): down` or similar.
2. **Process** — `lsof -i :8000` (vLLM) or `lsof -i :11434` (Ollama). If nothing listens, the model server is down; restart it before restarting Chump.
3. **Chump** — After the model is healthy, restart the bot (`scripts/self-reboot.sh` or your launchd job). The bot’s preflight only validates the model at startup intervals; it does not replace a dead inference server.

## OOM and crash loops

Symptoms: many `logs/oom-context-*.txt`, vLLM log shows load → `GET /v1/models` → immediate shutdown.

**Mitigations (pick what fits your machine):**

- Reduce model size or use a **quantization** that fits unified memory.
- Lower **parallelism**: e.g. vLLM-MLX `max_num_seqs=1` (many scripts already use this).
- **Smaller context** / default max tokens if the stack exposes them.
- **Stagger roles** so Farmer Brown is not hammering the model with health checks during a fragile boot (increase interval temporarily).

Deep tuning: [GPU_TUNING.md](GPU_TUNING.md), [OLLAMA_SPEED.md](OLLAMA_SPEED.md).

## Profiles

Canonical ports and env: [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md).  
Steady-run and retry scripts: [STEADY_RUN.md](STEADY_RUN.md).

## Cloud / cascade fallback

If local inference is down but **provider cascade** is enabled, heartbeats and some paths can still use cloud slots. See [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) and `scripts/heartbeat-cloud-only.sh` for headless/cloud-only mode.

## Model flap drill (reliability acceptance)

**Goal:** Prove Chump and roles **recover** after inference goes away and returns—market expectation under “reliability under real ops.”

**You will need:** Two terminals; local Ollama on `11434` (or vLLM on `8000` per [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)).

**Script (Ollama example):**

1. Start web or Discord Chump with a working model; confirm `curl -s http://127.0.0.1:11434/api/tags` succeeds.
2. In terminal A, run `./run-web.sh` (or Discord) and confirm chat or `/api/health` OK.
3. **Stop Ollama** (`Ctrl+C` on `ollama serve` or `killall ollama`). Send one chat or `curl` that hits the model — expect **clear error** (no silent hang).
4. **Restart Ollama** and `ollama pull` your model if needed.
5. Retry chat or health — record **wall seconds until first success** after restart.
6. If using **Farmer Brown / Sentinel**, check `logs/farmer-brown.log` for down/up transitions.

**Pass criteria (pilot):** Second successful model response within **5 minutes** of restart without editing `.env`; no zombie process requiring full OS reboot.

**Failure actions:** See **Quick triage** above; tighten [OLLAMA_SPEED.md](OLLAMA_SPEED.md) `keep_alive` if cold starts dominate.

## Degraded mode playbook (strategic alignment)

Use this when the PWA **Providers** tab shows **local inference not reachable**, chat hangs on “Thinking…”, or `/api/stack-status` reports `inference.models_reachable: false`.

| Step | Action |
|------|--------|
| 1 | **Confirm the probe:** `curl -sS -m 5 "$(echo $OPENAI_API_BASE | sed 's|/v1||')/models"` (or your base + `/models`). If it fails, the orchestrator cannot complete turns—fix the server before blaming Chump. |
| 2 | **MLX / vLLM OOM or crash loop** — See **OOM and crash loops** above; reduce model size, `max_num_seqs`, or context. Check `logs/oom-context-*.txt` and the vLLM/MLX process log. |
| 3 | **Fallback to Ollama (dev / rescue)** — Point `OPENAI_API_BASE=http://127.0.0.1:11434/v1`, `OPENAI_API_KEY=ollama`, pull a smaller model (`ollama pull qwen2.5:14b`), restart `./run-web.sh` or `./run-local.sh`. See [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md). |
| 4 | **Farmer Brown** — When `.env` targets **8000**, [scripts/farmer-brown.sh](../scripts/farmer-brown.sh) (via launchd or Mabel patrol) runs `keep-chump-online` / `restart-vllm-if-down.sh`. It is a **recovery** layer, not a substitute for a stable model config—tune the stack per **Quick triage** first. |
| 5 | **Cloud-only heartbeat** — If the Mac GPU stack must stay down, use [OPERATIONS.md](OPERATIONS.md) **Mode B: Cloud-Only Heartbeat** (`heartbeat-cloud-only.sh`) with cascade keys. |
| 6 | **Defense / pilot demos** — Prefer a **known-good** profile documented in [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md); avoid first-time MLX tuning during a sponsor call. |

**UX:** In the PWA sidecar **Providers** tab, Chump surfaces `stack-status.inference.error` when local `/v1/models` is unreachable so you do not have to dig in logs first.

Alignment context: [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md). For mistral.rs–centric phases and WPs (optional in-process backend), see [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) §7.

## Related

- `docs/OPERATIONS.md` — roles, logs, battle QA, degraded inference summary  
- `docs/DISCORD_TROUBLESHOOTING.md` — “Model server isn’t responding”
