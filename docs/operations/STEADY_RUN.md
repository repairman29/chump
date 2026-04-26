---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Keep Chump running steady (14B on 8000)

**Full operating standard (profiles, switching, prerequisites):** [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md).

Tuning and automation so the 14B model and Chump stay up with fewer connection drops and OOMs.

## 1. vLLM-MLX tuning (stability first)

Set these in **`.env`** so `serve-vllm-mlx.sh` and `restart-vllm-if-down.sh` use them. **Conservative (default)** keeps 14B stable on 24GB Macs:

| Variable | Recommended (steady) | If OOM / crash | If stable for days |
|----------|----------------------|-----------------|----------------------|
| `VLLM_MAX_NUM_SEQS` | 1 | 1 | 2 |
| `VLLM_MAX_TOKENS` | 4096 | 4096 | 8192 or 16384 |
| `VLLM_CACHE_PERCENT` | 0.12 | 0.12 | 0.15–0.18 |
| `VLLM_WORKER_MULTIPROC_METHOD` | spawn | spawn | spawn |

- **OOM or “connection closed”:** Keep defaults; quit other apps (see [GPU_TUNING.md](GPU_TUNING.md) §1 shed-load / chump-mode).
- **Stable for a while:** Try raising in `.env`: `VLLM_MAX_TOKENS=8192`, `VLLM_CACHE_PERCENT=0.15`, then restart vLLM.

## 2. Chump .env for steady 8000

```bash
# Model (14B on 8000 only)
OPENAI_API_BASE=http://localhost:8000/v1
OPENAI_MODEL=mlx-community/Qwen2.5-14B-Instruct-4bit

# One turn at a time so Discord and heartbeats don’t overload 8000
CHUMP_MAX_CONCURRENT_TURNS=1

# Optional: longer request timeout (default 300s); 14B can be slow
# CHUMP_MODEL_REQUEST_TIMEOUT_SECS=300

# Optional: keep Discord and 8000 up via keep-chump-online (when using 8000 it only tends 8000 + Discord)
# CHUMP_KEEPALIVE_DISCORD=1
```

The Rust client retries on connection errors (including “connection closed”) with delays 0, 1s, 2s, 5s and uses a 300s request timeout by default so long generations don’t hang forever.

## 3. Keep 8000 and Discord up

**Manual (when you need Chump):**

1. Start model: `./scripts/restart-vllm-if-down.sh`
2. Start Discord: `./run-discord.sh` (or run in tmux so it survives terminal close: `tmux new -s chump && ./run-discord.sh`)

**Automated (steady run):**

- **Restart vLLM when down:** Run `./scripts/restart-vllm-if-down.sh` every 5–10 minutes (cron or launchd). Example launchd: `scripts/restart-vllm-if-down.plist.example` → `~/Library/LaunchAgents/ai.chump.restart-vllm-if-down.plist`, then `launchctl load ...`.
- **Keep Discord + 8000:** Run `./scripts/keep-chump-online.sh` every 2 minutes (e.g. Farmer Brown’s launchd). With `OPENAI_API_BASE` pointing at 8000, keep-chump-online skips Ollama/embed and only ensures 8000 is up and optionally starts Discord if not running. Set `CHUMP_KEEPALIVE_DISCORD=1` in `.env` if you want it to start the bot.

See [OPERATIONS.md](OPERATIONS.md) for Farmer Brown, keep-chump-online, and Roles.

## 4. Heartbeats (self-improve) and 8000

- **HEARTBEAT_LOCK=1** (default when on 8000): Only one heartbeat round at a time; avoids overloading the model.
- **Intervals:** Use 10m or 8m for self-improve when on 8000; shorten to 5m/3m only if `./scripts/check-heartbeat-health.sh` shows mostly ok.
- If 8000 often dies mid-round, keep vLLM defaults (4096 / 0.12) and the restart-vllm launchd so the next round gets a fresh server.

## 5. Quick reference

| Goal | Action |
|------|--------|
| Start 14B on 8000 | `./scripts/restart-vllm-if-down.sh` |
| Start Discord | `./run-discord.sh` (or in tmux) |
| Restart 8000 when it crashes | launchd/cron: `./scripts/restart-vllm-if-down.sh` every 5–10 min |
| Keep Discord + 8000 tended | Farmer Brown or keep-chump-online every 2 min; `CHUMP_KEEPALIVE_DISCORD=1` |
| Fewer OOMs | Keep `VLLM_MAX_TOKENS=4096`, `VLLM_CACHE_PERCENT=0.12`; run shed-load / chump-mode before heavy use |
| Retries / timeout | Client retries 4× with backoff; `CHUMP_MODEL_REQUEST_TIMEOUT_SECS` (default 300) |

See also: [OPERATIONS.md](OPERATIONS.md) (Serve, Keep Chump running), [GPU_TUNING.md](GPU_TUNING.md) (OOM runbook, shed-load).

## 6. Soak / long-window notes (optional)

For **overnight or multi-day** runs, append a **dated** subsection here, in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md), or use the checklist in [SOAK_72H_LOG.md](SOAK_72H_LOG.md): SQLite file size + WAL behavior, model server uptime, `logs/` growth, and any `stack-status` anomalies. Roadmap: [ROADMAP.md](ROADMAP.md) **Architecture vs proof** → **Overnight / 72h soak**. Inference soak narrative: [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) §Soak.
