# Paramedic Daemon Supervision

**INFRA-1397** — launchd plist + NATS leader election for the chump paramedic daemon.

The paramedic daemon (`chump paramedic daemon`) triages open PRs every 10 minutes and
applies five rescue actions: `REBASE_DIRTY`, `RERUN_FLAKE`, `ALLOWLIST_EMIT_NO_REG`,
`SQUASH_INIT_LEAK`, `FILE_CLUSTER_RESCUE`. It is supervised by launchd and emits
`paramedic_heartbeat` events to `ambient.jsonl` each cycle.

## Installation

```bash
# Install (idempotent):
bash scripts/setup/install-paramedic.sh

# Verify:
bash scripts/setup/install-paramedic.sh --check

# Also wired into fleet bootstrap (META-066):
bash scripts/setup/chump-fleet-bootstrap.sh
```

This copies `scripts/setup/com.chump.paramedic.plist` to
`~/Library/LaunchAgents/com.chump.paramedic.plist` with two substitutions:

| Placeholder | Resolved to |
|---|---|
| `CHUMP_BIN_PLACEHOLDER` | `chump` binary path (env `CHUMP_BIN` → repo targets → `which chump`) |
| `CHUMP_LOG_DIR_PLACEHOLDER` | `~/Library/Logs/Chump` |

Logs: `~/Library/Logs/Chump/paramedic.{out,err}.log`

## Key launchd settings

| Key | Value | Why |
|---|---|---|
| `KeepAlive` | `true` | launchd restarts on crash |
| `RunAtLoad` | `true` | starts immediately on load |
| `ThrottleInterval` | `10s` | backs off 10s on crash loop |
| `StartInterval` | `600s` | baseline 10-min schedule |

The `--interval-secs 600` argument to the daemon means it sleeps between
cycles — `StartInterval` is a belt-and-suspenders fallback in case the
daemon exits normally (it should not).

## Tunable environment variables

Set these via `launchctl setenv` or `~/.chump-env` before starting the agent:

| Variable | Default | Effect |
|---|---|---|
| `CHUMP_PARAMEDIC_INTERVAL_SECS` | 600 | how often to run triage (plist `--interval-secs`) |
| `CHUMP_PARAMEDIC_BUDGET_SECS` | 90 | per-PR action wall-clock budget |
| `CHUMP_PARAMEDIC_DRY_RUN` | unset | set to `1` to observe without acting |
| `CHUMP_NATS_URL` | unset | enables NATS-KV leader election across machines |
| `CHUMP_PARAMEDIC_FORCE_LEADER` | unset | set to `1` to bypass election (manual override) |

## Leader election

Two processes can run simultaneously (e.g. dev machine + CI runner). Leader
election prevents both from acting on the same PR.

### Lockfile mode (default — single machine or shared filesystem)

When `CHUMP_NATS_URL` is not set:

- Leader writes `{machine, pid, started_at, renewed_at}` JSON to
  `.chump-locks/paramedic.leader` every **10 seconds** (mtime-based renewal).
- Standby checks the file's **mtime** every 10 seconds. If mtime is older than
  **30 seconds** (TTL expired) it tries to acquire.
- On the same machine, a dead PID detected via `kill -0` also releases the lock
  immediately (no need to wait the full TTL).

### NATS-KV mode (multi-machine fleet)

When `CHUMP_NATS_URL` is set and the `nats` CLI is reachable:

- Uses bucket `chump_paramedic`, key `leader`, with **TTL 30s** on the bucket.
- `nats kv create` (atomic — fails if key exists) is the election primitive.
- Leader renews by overwriting the key every 10s.
- When the leader crashes, the key expires after 30s and the next standby to call
  `nats kv create` wins.
- If NATS becomes unreachable mid-election, the daemon falls back to the
  lockfile path automatically.

## Failover timing

| Scenario | Detection | Action |
|---|---|---|
| Leader process crash (launchd machine) | launchd restarts within `ThrottleInterval` (10s) | No standby needed — launchd brings it back |
| Leader on separate machine crashes | standby detects stale mtime/NATS key within 30s | standby acquires; next cycle runs |
| Network partition (NATS unreachable) | NATS client error falls back to lockfile | local lockfile takes over |

## Health monitoring

The `paramedic_heartbeat` event (emitted each cycle) feeds into `chump health`:

```bash
chump health --slo-check   # exits non-zero if L4-SLO-1 is breached
```

**L4-SLO-1**: non-zero exit if `paramedic_heartbeat` has not appeared in the
last **15 minutes** AND at least one heartbeat was seen in the last hour (i.e. the
daemon was recently running but stopped).

If no heartbeat has ever been seen, the SLO reports "no data" and does not
breach (daemon not yet installed is not a regression).

### Checking status

```bash
# launchd status
bash scripts/setup/install-paramedic.sh --status
launchctl print gui/$(id -u)/com.chump.paramedic

# Recent heartbeats
grep '"kind":"paramedic_heartbeat"' ~/.chump-locks/ambient.jsonl | tail -5

# Standbys (if multi-machine)
grep '"kind":"paramedic_standby"' ~/.chump-locks/ambient.jsonl | tail -5

# Triage without acting (safe read-only)
chump paramedic triage
```

## Uninstall

```bash
bash scripts/setup/install-paramedic.sh --uninstall
```

This stops the launchd agent and removes the plist. The binary, logs, and
`.chump-locks/paramedic.leader` are left in place.

## Manual force leader

Set `CHUMP_PARAMEDIC_FORCE_LEADER=1` to bypass leader election and always run
as the active leader, regardless of what other processes claim. Useful when:

- Debugging in a shared environment where you want your instance to act.
- Running a one-off triage under `--dry-run`.

```bash
# Run one dry-run cycle as forced leader
CHUMP_PARAMEDIC_FORCE_LEADER=1 chump paramedic execute --dry-run

# Override launchd agent (until next restart)
launchctl setenv CHUMP_PARAMEDIC_FORCE_LEADER 1
```

## CI smoke test

```bash
bash scripts/ci/test-paramedic-leader-failover.sh
```

Covers: static analysis (function presence, TTL constants, event registrations),
solo dry-run heartbeat emission, two-process-race mutual exclusion, and NATS-down
lockfile fallback.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `install-paramedic.sh` exits non-zero: "chump binary not found" | `which chump` or `ls target/release/chump` | Run `cargo build --release` or set `CHUMP_BIN` |
| `launchctl print` shows `state = waiting` | Normal between cycles | Check logs for errors |
| `launchctl print` shows `state = throttled` | Crash loop | Check `paramedic.err.log`; usually bad env or missing `gh` auth |
| No heartbeats in ambient.jsonl | Daemon not loaded | Re-run `install-paramedic.sh` |
| Two instances both showing as leader | Lockfile not shared / NATS misconfigured | Set `CHUMP_NATS_URL` for multi-machine or ensure single launchd agent |
| `L4-SLO-1 BREACH` in `chump health` | Daemon crashed and not recovered | Check launchd logs; `launchctl kickstart` or reinstall |
