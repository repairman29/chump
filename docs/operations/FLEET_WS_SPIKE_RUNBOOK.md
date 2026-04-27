---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Fleet WebSocket Spike Runbook

Operational runbook for diagnosing and recovering from WebSocket connectivity failures in the Chump fleet (Mac ↔ Pixel Mabel ↔ cloud sessions).

See [FLEET_ROLES.md](FLEET_ROLES.md) for the roles involved.

## Architecture

```
Mac (Chump web :5173) ←── Tailscale ──→ Pixel (Mabel heartbeat)
        ↕                                       ↕
   vLLM-MLX :8000                        llama-server :8080
        ↕
  Together.ai / OpenAI (cascade)
```

Mabel uses SSH over Tailscale for all Mac-side operations. The web API (`/api/dashboard`, `/api/approve`) is also accessed via Tailscale.

## Symptoms and causes

| Symptom | Likely cause | Recovery |
|---------|-------------|----------|
| Mabel patrol round fails "SSH connection refused" | Tailscale not running on Mac or Pixel | `tailscale up` on both sides |
| `/api/dashboard` returns 504 | Chump web server dead (OOM or crash) | `mabel-farmer.sh` triggers `farmer-brown.sh` auto-recovery |
| `ALERT kind=silent_agent` in ambient.jsonl | Agent stopped heartbeating | Check `.chump-locks/` for stale lease; run `scripts/ops/stale-pr-reaper.sh` |
| vLLM-MLX not responding on :8000 | Metal OOM during model reload | `restart-vllm-if-down.sh`; reduce `VLLM_CACHE_PERCENT` to 0.12 |
| Discord bot offline | Bot process crashed | `ensure-mabel-bot-up.sh` on Pixel; `ensure-ship-heartbeat.sh` on Mac |

## Tailscale health check

```bash
# Mac
tailscale status
tailscale ping <pixel-tailscale-ip>

# Pixel (via adb or SSH)
tailscale status
```

## Fleet report

Mabel's **report** round posts a unified fleet report to Discord:

```bash
# Manually trigger fleet report from Mac
scripts/dev/heartbeat-ship.sh report
```

Report includes: Mac uptime, vLLM status, Ollama status, Chump web status, last ship heartbeat round, Mabel last seen.

## Recovery order

1. Confirm Tailscale connectivity (both sides)
2. Confirm Chump web server running: `curl http://localhost:5173/api/health`
3. Confirm vLLM-MLX: `curl http://localhost:8000/v1/models`
4. Confirm Ollama: `ollama list`
5. Restart stalled process: see `INFERENCE_STABILITY.md` OOM runbook
6. If all else fails: `CHUMP_PAUSED=1` kill switch; restart manually

## See Also

- [OPERATIONS.md](OPERATIONS.md) — Farmer Brown, Mabel farmer, Oven Tender
- [FLEET_ROLES.md](FLEET_ROLES.md) — fleet role definitions
- [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) — vLLM OOM runbook
- [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Mabel's roadmap and env vars
