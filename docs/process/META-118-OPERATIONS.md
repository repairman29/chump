# META-118 Daemon Operations Runbook

INFRA-2280 — scheduling activation for the META-118 wedge auto-dispatch chain.

## What runs

| Daemon label | Script | Cadence | Purpose |
|---|---|---|---|
| `com.chump.novel-wedge-classifier` | `scripts/coord/novel-wedge-classifier.sh` | every 15 min | Scans ambient.jsonl for recurring CI failure signatures; emits `wedge_class_detected` when novel |
| `com.chump.cascade-unblock-detector` | `scripts/coord/cascade-unblock-detector.sh` | every 5 min | After a `wedge_auto_fix` PR merges, rebases open PRs with the same failure signature |

Both emit `kind=meta_118_daemon_tick` at tick start for liveness monitoring.

## Install

```bash
bash scripts/setup/install-meta-118-daemons.sh
```

Idempotent — safe to re-run; unloads then reloads each plist. Logs go to
`~/Library/Logs/chump/novel-wedge-classifier.log` and
`~/Library/Logs/chump/cascade-unblock-detector.log`.

`chump-fleet-bootstrap.sh --check` validates both plists are loaded.

## Inspect

```bash
launchctl print gui/$(id -u)/com.chump.novel-wedge-classifier
launchctl print gui/$(id -u)/com.chump.cascade-unblock-detector
```

## Log tail

```bash
tail -f ~/Library/Logs/chump/novel-wedge-classifier.log
tail -f ~/Library/Logs/chump/cascade-unblock-detector.log
```

Tick events in ambient stream:
```bash
grep meta_118_daemon_tick .chump-locks/ambient.jsonl | tail -20
```

## Stop (temporary)

```bash
launchctl unload ~/Library/LaunchAgents/com.chump.novel-wedge-classifier.plist
launchctl unload ~/Library/LaunchAgents/com.chump.cascade-unblock-detector.plist
```

Or use the kill-switch env vars (no plist reload needed):
```bash
# Per-tick skip — set before next tick fires
export CHUMP_WEDGE_CLASSIFIER_SKIP=1       # stops classifier
export CHUMP_UNBLOCK_SKIP=1               # stops cascade-unblock
```

## Restart

```bash
bash scripts/setup/install-meta-118-daemons.sh
```

## Uninstall

```bash
bash scripts/setup/install-meta-118-daemons.sh --uninstall
```

## Confirm liveness

```bash
# Should show ticks from the last 20 min (classifier every 15, unblock every 5)
grep '"kind":"meta_118_daemon_tick"' .chump-locks/ambient.jsonl | tail -5
```

Missing ticks for >20 min indicates launchd misconfiguration or script crash —
check logs and re-run the installer.
