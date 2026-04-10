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

## Related

- `docs/OPERATIONS.md` — roles, logs, battle QA  
- `docs/DISCORD_TROUBLESHOOTING.md` — “Model server isn’t responding”
