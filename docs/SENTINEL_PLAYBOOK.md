# Sentinel Playbook for Mabel

Mabel (Sentinel) monitors the Mac's health (and optionally her own) and escalates when thresholds are exceeded so the fleet recovers or the operator is notified.

See also: [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md), [scripts/mabel-farmer.sh](../scripts/mabel-farmer.sh).

---

## Objective

- **Monitor** Mac stack (and optionally Pixel) using scripted probes and optional Web API.
- **Escalate** when thresholds are exceeded: run remote fix, then notify (Discord DM) or coordinate with Chump via `message_peer` when Chump should self-repair.

---

## Data sources (in order of use)

### Primary: mabel-farmer.sh diagnosis

Run `scripts/mabel-farmer.sh` (diagnose-only or with fix). It checks:

1. Tailscale reachability (ping)
2. SSH connectivity
3. Ollama (HTTP)
4. Mac model port (e.g. vLLM :8000)
5. Embed server
6. Discord bot process (SSH `pgrep`)
7. Chump health endpoint (optional: `MAC_HEALTH_PORT` → GET `/health`)
8. Heartbeat log (SSH `tail` of heartbeat-learn.log)
9. Pixel llama-server and bot (when `MABEL_CHECK_LOCAL=1`)

No Web API yet; see optional section below.

### Optional: Mac Web API

When **MAC_WEB_PORT** (e.g. 3000) is set on the Pixel, Sentinel can probe the Mac Web server:

- **GET** `http://<MAC_IP>:<MAC_WEB_PORT>/api/health`  
  Returns minimal liveness: `{"status":"ok","service":"chump-web"}`. When `CHUMP_WEB_TOKEN` is set on the Mac, send `Authorization: Bearer <token>`.

- **GET** `http://<MAC_IP>:<MAC_WEB_PORT>/api/dashboard`  
  Returns `ship_running`, `ship_summary` (round, round_type, status), `ship_log_tail`, `chassis_log`. Use for "what is Chump doing?" and "is ship heartbeat stuck?". Requires Bearer token when `CHUMP_WEB_TOKEN` is set.

**Env on Pixel (optional):**

- **MAC_WEB_PORT** — Mac Web server port (default 3000). If set, mabel-farmer and agent rounds can probe `/api/health` and optionally `/api/dashboard`.
- **CHUMP_WEB_TOKEN** — Bearer token for Mac Web API. Set this on the Pixel if the Mac has `CHUMP_WEB_TOKEN` set, so Mabel can call `/api/dashboard` for richer monitoring.

### Existing: SSH log tail

Via mabel-farmer or agent `run_cli`: SSH to Mac and `tail` of `logs/heartbeat-*.log`, `logs/farmer-brown.log`.

---

## Thresholds (escalation)

| Condition | Action |
|-----------|--------|
| **Hard failure** — Mac unreachable (Tailscale or SSH down) for 2 consecutive checks | Notify operator (Discord DM). Optionally `message_peer` Chump. |
| **Service failure** — After mabel-farmer fix run, diagnosis still shows need_fix (Ollama/model/Discord down) | Notify operator with last diagnosis snippet (e.g. "Mac stack still unhealthy after remote fix. Check logs."). |
| **Stale progress (optional)** — Web API dashboard shows `ship_running` true but `ship_summary` unchanged (same round/status) for >30 minutes | Log "ship possibly stuck". Optionally notify or `message_peer` Chump. |

---

## Actions

- **Diagnose:** Run `mabel-farmer.sh` (with or without `MABEL_FARMER_DIAGNOSE_ONLY=1`). Prefer scripted path; agent round can `run_cli` it and parse the log.
- **Fix:** Trigger remote fix (mabel-farmer already SSHs to Mac and runs farmer-brown.sh or `MABEL_FARMER_FIX_CMD`). Local fix: restart Pixel llama-server and bot via `start-companion.sh`.
- **Notify:** Use the `notify` tool (Discord DM to configured user). Use a short, actionable message and reference logs (e.g. `logs/mabel-farmer.log`, `logs/heartbeat-mabel.log`).
- **Coordinate:** Use `message_peer` to Chump only when escalation is "Chump should self-repair" (e.g. after remote fix failed and operator should be aware; Chump can then run battle QA or restart services).

---

## Reference

- Env vars: [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) (Mabel Farmer env table), [scripts/mabel-farmer.sh](../scripts/mabel-farmer.sh) (header).
- Mac health server: when `CHUMP_HEALTH_PORT` is set, the Mac runs a minimal HTTP server on that port; GET `/health` returns model, embed, memory, status (no auth). Use **MAC_HEALTH_PORT** on the Pixel to point at it.
