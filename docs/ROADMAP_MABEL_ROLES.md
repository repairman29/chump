# Roadmap: Mabel Takes Over the Farm

Migrate Chump's background monitoring roles from Mac-local launchd jobs to **Mabel on the Pixel**, running over Tailscale. Mabel becomes the independent observer — if the Mac stack goes sideways, the watchdog isn't on the same sinking ship.

**See also:** [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Mabel as an autonomous driver (heartbeat loop, unified reporting, research, peer_sync). Phase 1–2 extend this doc; Sprints 6–10 add mutual supervision, OCR, shared brain, QA verify, hybrid inference.

---

## Why

Today all five roles (Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender) run on the Mac via launchd. If the Mac freezes, panics, or Chump wedges hard enough to also wedge the monitoring scripts, there's no external observer. Mabel on the Pixel is always-on (Termux + `termux-wake-lock`), connected via Tailscale, and running her own stack independently.

**After this migration:**

- Mabel monitors the Mac stack remotely (SSH + HTTP probes over Tailscale).
- Mabel monitors her own local llama-server health.
- Mabel triggers remote repairs (SSH into Mac → `farmer-brown.sh` / `keep-chump-online.sh`).
- Mabel DMs Jeff on Discord when something's wrong and can't be auto-fixed.
- Mac-local launchd roles are retired (or kept as fallback only).

---

## Architecture

```
┌──────────────────────────────────────────────┐
│  Pixel (Mabel)              Tailscale: 100.x │
│  ┌──────────────┐                            │
│  │ mabel-farmer │──── SSH/HTTP ──────┐       │
│  │  (crond)     │                    │       │
│  └──────────────┘                    │       │
│  ┌──────────────┐                    │       │
│  │ llama-server │ (local health)     │       │
│  └──────────────┘                    │       │
│  ┌──────────────┐                    │       │
│  │ Mabel bot    │ (Discord notify)   │       │
│  └──────────────┘                    │       │
└──────────────────────────────────────│───────┘
                                       │
                              Tailscale mesh
                                       │
┌──────────────────────────────────────│───────┐
│  MacBook (Chump)            Tailscale: 100.y │
│                                      │       │
│  ┌──────────┐  ┌──────────┐  ┌──────┴─────┐ │
│  │ Ollama   │  │ Discord  │  │   sshd     │ │
│  │ (11434)  │  │   bot    │  │  (22)      │ │
│  └──────────┘  └──────────┘  └────────────┘ │
│  ┌──────────┐  ┌──────────┐                  │
│  │ Embed    │  │ Heartbeat│                  │
│  │ (18765)  │  │ loops    │                  │
│  └──────────┘  └──────────┘                  │
└──────────────────────────────────────────────┘
```

---

## Role migration plan

### Phase 1: Mabel Farmer (replaces Farmer Brown + Sentinel + Heartbeat Shepherd)

**Script:** `scripts/mabel-farmer.sh` (runs on Pixel)

Combines the duties of three Mac-local roles into one remote script:

| Old role (Mac) | Mabel Farmer equivalent |
|---|---|
| **Farmer Brown** (diagnose + fix) | HTTP probes from Pixel: Ollama `/api/tags`, model port `/v1/models`, embed port. SSH fallback for process-level checks (`pgrep`). Remote fix via `ssh mac "farmer-brown.sh"`. |
| **Sentinel** (alert on repeated failures) | Built into `mabel-farmer.sh`: if post-fix diagnosis still fails, DM the configured user via Mabel's Discord bot. Replaces ntfy/webhook with direct Discord DM. |
| **Heartbeat Shepherd** (check heartbeat health) | SSH reads `tail logs/heartbeat-learn.log` on Mac; flags recent failures in diagnosis output. |

**What Mabel Farmer checks (in order):**

1. Tailscale reachability (ping)
2. SSH connectivity
3. Ollama (HTTP probe)
4. Model API port (HTTP probe)
5. Embed server (HTTP probe)
6. Discord bot process (SSH `pgrep`)
7. Chump health endpoint (HTTP, optional)
8. Heartbeat log (SSH `tail`)
9. Local llama-server on Pixel (HTTP probe)

**Env vars** (in `~/chump/.env` on the Pixel):

```bash
# Required
MAC_TAILSCALE_IP=100.x.y.z

# Optional (defaults shown)
MAC_TAILSCALE_USER=jeff
MAC_SSH_PORT=22
MAC_CHUMP_HOME=~/Projects/Chump
MAC_OLLAMA_PORT=11434
MAC_MODEL_PORT=8000
MAC_EMBED_PORT=18765
MAC_HEALTH_PORT=
MABEL_FARMER_INTERVAL=120
MABEL_FARMER_DIAGNOSE_ONLY=0
MABEL_CHECK_LOCAL=1
MABEL_LOCAL_PORT=8000
MABEL_DISCORD_NOTIFY=1
```

**Schedule on Pixel (crond in Termux):**

```bash
# Option A: cron (install cronie in Termux: pkg install cronie && crond)
*/2 * * * * cd ~/chump && bash scripts/mabel-farmer.sh >> logs/mabel-farmer.log 2>&1

# Option B: loop mode (in start-companion.sh or a separate tmux/screen)
MABEL_FARMER_INTERVAL=120 nohup bash ~/chump/scripts/mabel-farmer.sh >> ~/chump/logs/mabel-farmer.log 2>&1 &
```

### Phase 2: Memory Keeper (remote)

Memory Keeper checks the SQLite DB and embed server. Since both are on the Mac, Mabel can do this via SSH:

```bash
ssh mac "cd ~/Projects/Chump && sqlite3 sessions/chump_memory.db 'SELECT COUNT(*) FROM chump_memory'"
```

Add as an optional check in `mabel-farmer.sh` gated by `MABEL_CHECK_MEMORY=1`. Low priority — memory rarely breaks.

### Phase 3: Keep on Mac (local-only)

These stay as Mac-local launchd jobs:

| Role | Why local |
|---|---|
| **Oven Tender** | Starts `ollama serve` locally. Can't be launched over SSH reliably (launchd session issues, GPU context). Mabel can *detect* Ollama is down and DM the configured user, but the actual start is best done locally. |
| **keep-chump-online.sh** | Mabel triggers it remotely via SSH, but the script itself runs on the Mac (starts processes, manages ports). |
| **self-reboot.sh** | Kills and restarts the Discord bot. Runs on Mac; Mabel can trigger via SSH. |
| **launchctl load/unload** | macOS-specific; no remote equivalent. |

### Phase 4: Unified status report

Mabel sends a combined health report covering both devices:

```
Mabel Farmer Report (2026-03-13 10:00 UTC)
──────────────────────────────────
Mac (100.x.y.z):
  Tailscale: ok
  Ollama:    up
  Model:     up (8000)
  Embed:     up (18765)
  Discord:   running
  Heartbeat: ok (last round 8m ago)
Pixel (local):
  llama-server: up (8000)
  Mabel bot:    running
──────────────────────────────────
```

Sent via hourly DM (or on-demand via `!status` Discord command). Replaces the Mac-only `hourly-update-to-discord` job with a system-wide view.

---

## Setup checklist

### Prerequisites

- [ ] Tailscale running on both Mac and Pixel; both devices visible in the mesh.
- [ ] SSH enabled on Mac (System Settings → General → Sharing → Remote Login).
- [ ] SSH key from Pixel to Mac: `ssh-keygen` on Pixel, copy pubkey to Mac's `~/.ssh/authorized_keys`.
- [ ] Verify: `ssh -p 22 jeff@100.x.y.z "echo ok"` from Termux.
- [ ] Mabel's `.env` on Pixel has `MAC_TAILSCALE_IP`, `DISCORD_TOKEN`, `CHUMP_READY_DM_USER_ID`.
- [ ] **After a network swap:** update Mac `~/.ssh/config` (HostName for termux) and Pixel `~/chump/.env` (MAC_TAILSCALE_IP). See [NETWORK_SWAP.md](NETWORK_SWAP.md) and `./scripts/check-network-after-swap.sh`.

### Deploy

1. Push `scripts/mabel-farmer.sh` to Pixel: `scp` via Termux SSH, or use `deploy-all-to-pixel.sh` (pushes scripts to `~/chump/scripts/`).
2. On Pixel (Termux): ensure `~/chump/scripts/mabel-farmer.sh` is executable: `chmod +x ~/chump/scripts/mabel-farmer.sh`
3. Test diagnose-only: `MABEL_FARMER_DIAGNOSE_ONLY=1 bash ~/chump/scripts/mabel-farmer.sh`
4. Start loop: `MABEL_FARMER_INTERVAL=120 nohup bash ~/chump/scripts/mabel-farmer.sh >> ~/chump/logs/mabel-farmer.log 2>&1 &`
5. (Optional) Install crond: `pkg install cronie && crond` and add the cron line above.

### Retire Mac-local roles (after validation)

Once Mabel Farmer is running stable for a few days:

```bash
# On Mac: unload the three migrated roles
launchctl unload ~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist
launchctl unload ~/Library/LaunchAgents/ai.chump.sentinel.plist
launchctl unload ~/Library/LaunchAgents/ai.chump.heartbeat-shepherd.plist

# Keep these loaded:
# ai.chump.oven-tender.plist     (local Ollama management)
# ai.chump.memory-keeper.plist   (until Phase 2 is validated)
```

Update `install-roles-launchd.sh` and `unload-roles-launchd.sh` to skip the migrated roles, or add a `MABEL_MANAGES_FARM=1` env flag that makes them no-op.

---

## Future: Mabel as single pane of glass

Once Phases 1–4 are done, Mabel is the unified monitoring layer:

- **Mac stack**: Ollama, model, embed, Discord bot, heartbeat — all checked remotely.
- **Pixel stack**: local llama-server, Mabel bot — checked locally.
- **Alerts**: single Discord DM channel with Mabel's perspective on both devices.
- **Self-heal**: Mabel SSHes into Mac to run `farmer-brown.sh`, `keep-chump-online.sh`, or `self-reboot.sh` as needed.
- **Escalation**: if SSH itself is broken (Mac truly down), Mabel DMs Jeff "Mac unreachable — intervention needed."

This also opens the door for Mabel to manage additional devices later (e.g., a second build server, a cloud VPS) using the same SSH-probe pattern.

---

## Related docs

- [OPERATIONS.md](OPERATIONS.md) — existing role descriptions and launchd setup.
- [ANDROID_COMPANION.md](ANDROID_COMPANION.md) — deploying Chump/Mabel on the Pixel.
- [MABEL_FRONTEND.md](MABEL_FRONTEND.md) — Mabel naming and Discord setup.
- [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) — Pixel performance tuning.
