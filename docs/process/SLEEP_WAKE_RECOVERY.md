# Sleep/wake recovery (RESILIENT-169)

The fleet substrate is a MacBook. Closing the lid is normal operator behavior —
the bug was that the fleet treated sleep as **death** instead of a **pause**.
The June 22→28 six-day outage was exactly this: full system sleep suspended
every fleet process AND the oauth refresh daemon, and on each brief DarkWake
the stale auth-status cache (CREDIBLE-147) blocked self-heal.

## The three layers

| Layer | What | Who acts |
|---|---|---|
| **Wake recovery** (this gap) | `com.chump.wake-recovery` LaunchAgent runs `tools/chumpwake` (Swift, `NSWorkspace.didWakeNotification`); on every wake it runs [`scripts/ops/wake-recovery.sh`](../../scripts/ops/wake-recovery.sh): busts the auth cache, re-probes validity, kickstarts farmer + integrator + merge-queue-monitor, emits `kind=wake_recovery` | automatic |
| **Stay-awake on AC** | `sudo pmset -c disablesleep 1` — lid-close on **power** keeps working (this is what `chump-mode grind` sets, once `chump-mode setup-sudo` has been run). On battery the machine still sleeps, deliberately, to protect the battery; wake recovery covers the resume. | operator, one-time sudo setup |
| **Durable end-state** | Move the substrate off the laptop onto the always-on Pi-mesh actions-runner (INFRA-1543) — then laptop sleep is irrelevant. | roadmap |

## Install / verify

```bash
bash scripts/setup/install-wake-recovery.sh
launchctl print "gui/$(id -u)/com.chump.wake-recovery" | grep state   # → running
```

## Wake test (documented per AC)

1. On AC power with the fleet in `grind`, close the lid ~30 s, reopen.
2. Within ~15 s the daemon fires (10 s settle delay for network/keychain):
   ```bash
   grep wake_recovery .chump-locks/ambient.jsonl | tail -1
   # → {"ts":"…","kind":"wake_recovery","auth_ok":true,"kicked":"dev.chump.farmer-brown,…"}
   tail -5 /tmp/chump-wake-recovery.log
   ```
3. Within one farmer TTL window (~1–5 min): worker processes present
   (`pgrep -f 'AGENT_ID=[0-9]+ .*worker.sh'`) and ChumpBar back to 🟢.

**Pool keeper (RESILIENT-177).** Wake recovery kicks daemons, but a dead tmux
server (hibernate, memory pressure) needs a full relaunch: `com.chump.fleet-pool-keeper`
(300s) relaunches the fleet whenever worker heartbeats all go stale while
`fleet-mode` says grind/travel — with a 600s cooldown and a 3-restores/hour
storm limit that escalates instead of thrashing (`kind=fleet_pool_restored`).

Handler-path testing without sleeping the machine:
`bash scripts/ops/wake-recovery.sh` runs the full routine directly (same
assertions), and `scripts/ci/test-wake-recovery.sh` covers it headlessly.
