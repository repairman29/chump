# After a network swap

When you change Wi‑Fi or networks, IPs can change. Use this checklist so **Chump (Mac)** and **Mabel (Pixel)** stay reachable and using the latest specs.

## What to update

### 1. Mac → Pixel (SSH and deploy)

**File:** `~/.ssh/config` on the Mac

- Update the **HostName** for `Host termux` to the Pixel’s **current IP** (same Wi‑Fi or Tailscale).
- Leave **Port 8022** and **User** (Termux `whoami`) as-is unless you changed them.

**Get Pixel IP:**

- **Tailscale:** On the Pixel (Termux), run `tailscale ip -4` (or check the Tailscale app).
- **Wi‑Fi only:** On the Pixel, run `ip addr` or check Settings → Network → Wi‑Fi → IP.

Example after update:

```text
Host termux
    HostName 100.xx.xx.xx
    Port 8022
    User u0_a314
    IdentityFile ~/.ssh/termux_pixel
```

**Verify:** From the Mac run `ssh -o ConnectTimeout=10 -p 8022 termux 'echo ok'`. If that works, deploy and Mabel SSH from Mac are good.

### 2. Pixel → Mac (Mabel farmer, heartbeat, hybrid inference)

**File:** `~/chump/.env` on the **Pixel** (Termux)

- **MAC_TAILSCALE_IP** — Mac’s current Tailscale IPv4. Mabel uses this for SSH and (if set) for `MABEL_HEAVY_MODEL_BASE`.
- Optionally **MAC_TAILSCALE_USER**, **MAC_SSH_PORT** (default 22), **MAC_CHUMP_HOME** if they differ from defaults.

**Get Mac IP:**

- On the Mac run: `tailscale ip -4`

Then on the Pixel set (e.g. `nano ~/chump/.env`):

```bash
MAC_TAILSCALE_IP=100.yy.yy.yy
# MAC_TAILSCALE_USER=jeff
# MAC_SSH_PORT=22
```

**Hybrid inference (Mac 14B from Pixel):** If you use `MABEL_HEAVY_MODEL_BASE`, point it at the Mac’s reachable IP and port 8000:

```bash
MABEL_HEAVY_MODEL_BASE=http://<MAC_TAILSCALE_IP>:8000/v1
```

The Mac’s model server (vLLM-MLX) must listen on an address the Pixel can reach (e.g. bind to `0.0.0.0:8000` or the Tailscale interface). See [ANDROID_COMPANION.md](ANDROID_COMPANION.md#hybrid-inference).

### 3. Mac .env (optional)

If Chump or scripts use the Pixel host/port explicitly:

- **PIXEL_SSH_HOST** — SSH host alias (default `termux`); only needed if you use a different name in `~/.ssh/config`.
- **PIXEL_SSH_PORT** — default `8022`; set only if Termux sshd uses another port.
- **DEPLOY_PORT** — same as PIXEL_SSH_PORT when running `deploy-all-to-pixel.sh` or `deploy-mabel-to-pixel.sh`.

No change needed if you only use `termux` and port 8022 in SSH config.

## Quick check script (Mac)

From the Chump repo on the Mac:

```bash
./scripts/check-network-after-swap.sh
```

This prints the Mac’s Tailscale IP, tests `ssh termux`, and reminds you to set **MAC_TAILSCALE_IP** on the Pixel.

**Inference mesh (optional):** If you use the iPhone node (Tailscale :8889) for fallback, delegate, or Mabel heavy, see [INFERENCE_MESH.md](INFERENCE_MESH.md). After a network swap, update the iPhone URL in `.env` if its Tailscale IP changed; run `./scripts/check-inference-mesh.sh` to see which nodes are up.

## Restart after updating

1. **Mac:** No need to restart Chump or vLLM just for IP changes; they bind to localhost or 0.0.0.0. Restart only if you changed something that requires it.
2. **Pixel:** After editing `~/chump/.env`, restart Mabel so she picks up the new MAC_TAILSCALE_IP:
   ```bash
   ssh -p 8022 termux 'cd ~/chump && pkill -f "chump.*--discord" 2>/dev/null; nohup ./start-companion.sh --bot >> logs/companion.log 2>&1 &'
   ```
   If you use mabel-farmer or heartbeat-mabel, they’ll use the new .env on the next run.

## Mabel not responding / downtime

If Mabel stops replying (Android killed the app, crash, or network blip), the Discord bot may be down while llama-server is still up. On the Pixel run:

```bash
bash ~/chump/scripts/ensure-mabel-bot-up.sh
```

That starts the bot if it’s not running (and if the model server is up). To recover automatically after downtime, run it every few minutes from cron (Termux: `pkg install cronie && crond`, then add a line like `*/5 * * * * cd ~/chump && bash scripts/ensure-mabel-bot-up.sh >> logs/ensure-mabel.log 2>&1`).

## Summary

| Where        | What to update after network swap                    |
|-------------|------------------------------------------------------|
| Mac `~/.ssh/config` | `Host termux` → **HostName** = Pixel’s current IP   |
| Pixel `~/chump/.env` | **MAC_TAILSCALE_IP** = Mac’s current Tailscale IP   |
| Pixel `~/chump/.env` | **MABEL_HEAVY_MODEL_BASE** if you use hybrid inference |

Use `tailscale ip -4` on each device to get current IPs; then run `./scripts/check-network-after-swap.sh` on the Mac to verify SSH to Pixel.
