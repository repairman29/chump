# Automation snippets (cron / launchd)

Copy-paste starting points for **headless** Chump: autonomy ticks, ship autopilot (API), and optional Discord notify on failure. Full ops context: [OPERATIONS.md](OPERATIONS.md).

## Prerequisites

- Repo root on disk; `.env` with **`DISCORD_TOKEN`** and **`CHUMP_READY_DM_USER_ID`** if you use **`chump --notify`** (stdin → DM).
- Built **`target/release/chump`** recommended for cron (faster than `cargo run`).
- Web token **`CHUMP_WEB_TOKEN`** if you call HTTP APIs from another host ([`scripts/autopilot-remote.sh`](../scripts/autopilot-remote.sh)).

## Autonomy once (`scripts/autonomy-cron.sh`)

Runs **`--reap-leases`** then one **`--autonomy-once`**; appends to **`logs/autonomy-cron.log`**. On **command failure** the script exits non-zero ( **`set -e`** inside the logged block).

### Cron (user crontab)

```cron
# Every 20 minutes — adjust path and assignee
*/20 * * * * cd /path/to/Chump && ./scripts/autonomy-cron.sh
```

### Cron + notify on failure

```cron
*/20 * * * * cd /path/to/Chump && ( ./scripts/autonomy-cron.sh || echo "autonomy-cron failed — see logs/autonomy-cron.log" | /path/to/Chump/target/release/chump --notify )
```

### launchd (macOS) — skeleton

1. Copy to `~/Library/LaunchAgents/ai.chump.autonomy-cron.plist`.
2. Replace **`/path/to/Chump`** and **`/path/to/log`** (stdout/stderr).
3. `launchctl load ~/Library/LaunchAgents/ai.chump.autonomy-cron.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.chump.autonomy-cron</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd /path/to/Chump &amp;&amp; ./scripts/autonomy-cron.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>1200</integer>
  <key>StandardOutPath</key>
  <string>/path/to/Chump/logs/autonomy-launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/path/to/Chump/logs/autonomy-launchd.err.log</string>
</dict>
</plist>
```

For **notify on failure** under launchd, use a one-line wrapper script that runs `autonomy-cron.sh` and pipes a message to `chump --notify` on non-zero exit (same idea as the cron example).

## Weekly / daily digest (optional)

- **Morning briefing DM:** [`scripts/morning-briefing-dm.sh`](../scripts/morning-briefing-dm.sh) — schedule with cron or launchd ([OPERATIONS.md](OPERATIONS.md) “Morning briefing DM”).
- **COS weekly snapshot:** `scripts/cos-weekly-snapshot.plist.example` via [`install-roles-launchd.sh`](../scripts/install-roles-launchd.sh) or your own schedule ([OPERATIONS.md](OPERATIONS.md) COS section).

## Ship autopilot (API, not cron)

Autopilot keeps **`heartbeat-ship`** aligned with desired state; control from PWA **Providers** (Start/Stop) or **`POST /api/autopilot/start|stop`** — see [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) and [OPERATIONS.md](OPERATIONS.md) **Ship autopilot**.

## PWA

The static PWA does not read this file at runtime; keep snippets here and link from ops docs when adding dashboard copy.
