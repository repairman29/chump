# Autonomous Mode — "I'm going on vacation, fleet keep running"

**INFRA-625** | Pairs with INFRA-622 (multi-auth), INFRA-608 (cost-watch), INFRA-617 (kpi report)

## What it is

When the operator has been absent for longer than the configured threshold (default **4 hours**),
Chump automatically shifts into *autonomous mode*. The fleet continues working, but under tighter
constraints that minimise spend and maximise resilience while no human is watching.

## Presence detection

Detection uses two sources (checked in order):

| Source | How to set |
|---|---|
| `CHUMP_OPERATOR_LAST_SEEN_UNIX` env var | Set by the launchd poller, NATS heartbeat bridge, or shell hook |
| mtime of `CHUMP_OPERATOR_ACTIVITY_PATH` | Defaults to `~/.claude/`; updated automatically by Claude Code IDE |

If **no signal is available**, the fleet assumes the operator is present (safe default — never
auto-restricts when uncertain).

The launchd poller (`install-autonomous-mode-launchd.sh`) runs every 15 minutes and writes
`~/.chump-operator-env` so fleet-worker subprocesses inherit the timestamp.

## Autonomous-mode behaviours

When `absent_hours ≥ CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS`:

### (a) Free-tier cascade only

Provider slots whose `CHUMP_PROVIDER_N_NAME` contains `anthropic` or `claude`, or whose
`CHUMP_PROVIDER_N_TIER` is not `free`, are disabled. Only Cerebras, Groq, Gemini, and other
free-tier slots remain active. This keeps spend at $0 while the operator is away.

Env vars exported by `AutonomousPolicy::cascade_env_overrides()`:

```
CHUMP_AUTONOMOUS_MODE=1
CHUMP_PROVIDER_<N>_ENABLED=0   # for each non-free slot
CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD=<cap>
```

### (b) P0 gaps only

The gap picker adds `priority = 'P0'` to its SQL filter (`AutonomousPolicy::picker_filter()`).
Only true unblockers are picked while the operator is offline. P1/P2 work waits.

### (c) Daily cost cap

`CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD` (default **$1.00**) is enforced per fleet session.
When the running cost from `chump_cost_tracker` reaches the cap, the current work unit halts
cleanly and the event is recorded in the digest.

### (d) Operator-return digest

Every significant event (gap shipped, cap reached, credential warning) is appended as a
JSON-L entry to:

```
CHUMP_AUTONOMOUS_DIGEST_PATH   (default: ~/.chump-autonomous-digest.jsonl)
```

On return, run:

```bash
chump kpi report --digest ~/.chump-autonomous-digest.jsonl
```

to get a summary of what the fleet did while you were away.

### (e) Halt on irrecoverable credential failure

If a provider slot returns an auth error **and** no free-tier fallback is available, the fleet:

1. Appends an `operator_recall` entry to the digest.
2. Emits a `fleet_halt` event to `ambient.jsonl`.
3. Exits with a non-zero status — the launchd plist will not auto-restart on `fleet_halt`.

The halt message reads:

```
OPERATOR RECALL REQUIRED — irrecoverable credential failure: <reason>.
Fleet has halted. Re-run `chump fleet start` after refreshing credentials.
```

## Ambient events

| Event kind | Meaning |
|---|---|
| `autonomous_mode_entered` | Threshold crossed; fleet switched to restricted mode |
| `autonomous_mode_exited` | Operator returned; normal mode resumed |
| `operator_recall` | Credential failure; fleet halted |
| `fleet_halt` | Fleet has stopped; operator action required |

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS` | `4` | Hours before autonomous mode activates |
| `CHUMP_OPERATOR_ACTIVITY_PATH` | `~/.claude/` | Path whose mtime signals operator presence |
| `CHUMP_OPERATOR_LAST_SEEN_UNIX` | _(unset)_ | Explicit Unix timestamp override (NATS bridge) |
| `CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD` | `1.00` | Hard daily spend ceiling in autonomous mode |
| `CHUMP_AUTONOMOUS_DIGEST_PATH` | `~/.chump-autonomous-digest.jsonl` | Operator-return digest file |
| `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | Ambient event stream |

## Setup

```bash
# Install the presence poller (idempotent):
bash scripts/setup/install-autonomous-mode-launchd.sh

# Verify it loaded:
launchctl list | grep dev.chump.autonomous-mode

# Check the env file fleet workers will read:
cat ~/.chump-operator-env
```

## Integration points

- **`src/operator_presence.rs`** — `detect()`, `AutonomousPolicy`
- **`src/provider_cascade.rs`** — reads `CHUMP_AUTONOMOUS_MODE` + per-slot `ENABLED` vars
- **`crates/chump-cost-tracker`** — `check_ceiling()` used by `AutonomousPolicy::check_cost_cap()`
- **INFRA-608 `chump cost-watch --hard-cap`** — complementary per-session hard cap
- **INFRA-617 `chump kpi report`** — renders the operator-return digest
- **INFRA-622 multi-auth** — provides the free-tier credential pool autonomous mode relies on
