# Autopilot Model (post-MISSION-007 unified)

> **One toggle, two layers.** Operator hits ONE switch (PWA toggle or `chump fleet autopilot start`); both layers respond. This doc explains what each layer does so when something fails, you know which one to look at.

## Why two layers?

Historically the codebase grew two parallel "autopilot" surfaces:

| Layer | What it manages | When it shipped | Surface |
|---|---|---|---|
| **Worker autopilot** (Rust) | A single ship-loop process that picks gaps + drives PRs to merge | pre-2026-05 | `autopilot::start_autopilot()` in `src/autopilot.rs`; PWA toggle (PRODUCT-115); `/api/autopilot/start` |
| **Daemon-set autopilot** (bash) | 10 launchd plists (pr-auto-rebase, pulse-consumer, transient-retrigger, oracle-refresh, curator-jit-scheduler, opus-curator, emergency-fast-path, fleet-autopilot heartbeat, refresh-runner-binary, auto-arm-sweeper) | META-090 (2026-05-25) | `bash scripts/coord/fleet-autopilot.sh start`; `/api/autopilot/start` (post-MISSION-007) |

Until MISSION-007 these were independent. Operator could start the Rust autopilot via PWA and have NO daemons running, or run the bash script and have no ship-loop. Confusing.

## How the bridge works (post-MISSION-007)

```
              ┌─────────────────────────────────────┐
              │ PWA <chump-autopilot-toggle> click  │
              │   OR                                │
              │ POST /api/autopilot/start           │
              │   OR                                │
              │ chump fleet autopilot start (EFFECTIVE-025) │
              └─────────────────────────────────────┘
                             │
                             ▼
              ┌─────────────────────────────────────┐
              │ handle_autopilot_start() in web_server.rs │
              │   1. autopilot::start_autopilot()          │
              │      → starts Rust worker ship-loop        │
              │   2. invoke_daemon_set("start")            │
              │      → shells bash scripts/coord/fleet-autopilot.sh start │
              │      → installs/loads 10 launchd plists    │
              └─────────────────────────────────────┘
                             │
                             ▼
              ┌─────────────────────────────────────┐
              │ Returns unified JSON:                │
              │  { ok: true,                         │
              │    worker: { ok, state },            │
              │    daemon_set: { available, status, … },│
              │    message: "Unified autopilot start │
              │              fired both layers" }    │
              └─────────────────────────────────────┘
```

Stop is symmetric: bash first (graceful launchctl unload), then Rust worker (kills ship-loop process).

Status returns combined state — operator sees both layers' health in one response.

## When one layer fails

The handlers are designed to NOT block on either layer's failure. If the Rust worker fails to start but the daemon-set succeeds, you get:
```json
{
  "ok": true,
  "worker": {"ok": false, "error": "ship_pid already discovered"},
  "daemon_set": {"available": true, "exit_code": 0, "stdout_tail": [...]},
  "message": "Unified autopilot start fired both layers …"
}
```

Operator can see which layer is healthy + which needs attention.

## How to debug

| Symptom | Likely layer | Diagnostic |
|---|---|---|
| PWA toggle is green but PRs aren't shipping | Worker (Rust) | `chump fleet autopilot status` → look at `worker.state` |
| Daemons absent from `launchctl list` | Daemon-set (bash) | `bash scripts/coord/fleet-autopilot.sh status` → look at `loaded` count |
| Status endpoint returns 500 | `invoke_daemon_set` shell failure | Check `.chump-locks/autopilot-logs/heartbeat-stderr.log` |
| `daemon_set.available: false` in JSON | bash script missing on disk | Verify `scripts/coord/fleet-autopilot.sh` exists in CHUMP_REPO |

## Why we kept both layers (not collapsed)

The Rust worker is a **single in-process ship-loop**. The daemon-set is **many parallel cron-driven background processes**. They solve different problems:

- Worker: deterministic gap-picking + claim + push under one lock
- Daemons: per-concern long-running tasks that can fire independently (auto-rebase, pulse-consumer, oracle-refresh, etc)

Collapsing them into one would require either making the daemons in-process threads (loses the launchd-survival property) or making the worker a daemon (loses the in-memory lock). The bridge model preserves both properties at the cost of "two layers to reason about."

## Future work

- **EFFECTIVE-025**: wire `chump fleet autopilot` CLI subcommand that proxies to bash script (so CLI users have the same toggle PWA users have).
- **EFFECTIVE-026**: PWA cockpit panel that renders the 10-daemon health (per-layer green/red) instead of just one aggregate toggle.
- **EFFECTIVE-027**: live wedge-watch tail in PWA so operator sees W-001..W-012 signatures fire in real-time.

## Acceptance verified

After MISSION-007 ships:
1. Click PWA autopilot toggle → both Rust ship-loop AND 10 launchd daemons fire.
2. `/api/autopilot/status` returns `{worker:…, daemon_set:…}` with both health snapshots.
3. CI test `scripts/ci/test-autopilot-unified.sh` asserts the bridge wiring (source-contract + behavior smoke).

This is the "ONE toggle, ONE status" outcome promised by MISSION-007.
