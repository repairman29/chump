# Disk-Pressure Protocol (DISK_PRESSURE_PROTOCOL.md)

**Audience:** every Chump agent (operator, Opus, Sonnet sub-agents, automated curators).
**Authority:** canonical reference for what each role does when disk pressure rises.
**Filed under:** INFRA-2304 (reactive wiring), INFRA-2303 (sccache+incremental reapers),
META-128 (pre-action disk planning), INFRA-2188 (chump-runner growth).

## Why this doc exists

On 2026-05-30 the disk hit 95% capacity. Two `disk_critical` ALERTs fired into
`ambient.jsonl` and **nothing automated reacted between them** — the operator
had to triage manually. Investigation found that every primitive existed
(emitters, reapers, pager) but they were not wired end-to-end. Operator
quote: "WTF is this happening... we should not ever have these surprises.
Are we not wired up to automate this?"

INFRA-2304 wired the missing connections. This doc is the standing reference
so future agents do not relearn the chain.

## The chain (mental model)

```
                                 ┌──────────────────────────────────┐
                                 │ disk-health-monitor (5min cron)  │ ─┐
EMITTERS                         │ disk-pressure-watchdog (15min)   │ ─┤
                                 │ reaper-instrumentation (per-call)│ ─┤
                                 └──────────────────────────────────┘  │
                                                                       ▼
                       ┌──────────────────────────────────────────────────┐
EVENT BUS              │  .chump-locks/ambient.jsonl  kind=disk_critical  │
                       └──────────────────────────────────────────────────┘
                                            │
                       ┌────────────────────┼────────────────────┐
                       ▼                    ▼                    ▼
              ┌────────────────┐   ┌─────────────────┐   ┌─────────────────┐
REACTORS      │ worker.sh      │   │ disk-critical-  │   │ chump gap       │
              │ pauses 5min    │   │ reactor (NEW)   │   │ reserve / claim │
              │ (passive)      │   │ tier-up + page  │   │ blocks via SLO  │
              └────────────────┘   └────────┬────────┘   └─────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────────────┐
ACTUATORS              │  disk-pressure-reaper.sh --execute --tier <N>   │
                       │  (delegates to target-dir-reaper at higher N)   │
                       │  + sccache-reaper.sh (INFRA-2303)               │
                       │  + git worktree prune                           │
                       └─────────────────────────────────────────────────┘
                                            │
                       ┌────────────────────┴────────────────────┐
                       ▼                                         ▼
              ┌────────────────────┐                    ┌────────────────────┐
ESCALATION    │ Sufficient reap?   │ ─── yes ───▶       │ done — emit metric │
              │ post free% ≥ thr?  │                    │ kind=disk_critical │
              └────────┬───────────┘                    │ _reactor_fired     │
                       │ no                             └────────────────────┘
                       ▼
              ┌──────────────────────────────────────────┐
PAGER         │  operator-recall.sh --condition          │
              │    DISK_CRITICAL --reason "..."          │
              │  emits kind=operator_recall              │
              │  POSTs to CHUMP_OPERATOR_RECALL_URL      │
              └──────────────────────────────────────────┘
```

## Tier ladder (current thresholds)

| Tier | Free disk     | Reap aggression                                            |
|------|---------------|------------------------------------------------------------|
| 0    | ≥ 50 GB       | idle — no action                                           |
| 1    | 20-50 GB      | `target/` idle > 6h + `git worktree prune` (INFRA-2303)    |
| 2    | 10-20 GB      | target/ idle > 2h + merged-and-deleted whole-worktree + sccache-reaper (INFRA-2303) |
| 3    | 5-10 GB       | whole-worktree idle > 30min + `target/debug/incremental` rm (INFRA-2303) |
| 4    | < 5 GB (RED)  | Tier 3 + `operator-recall.sh --condition DISK_CRITICAL`    |

The reactor (`disk-critical-reactor.sh`) bumps tier by 1 on every
`disk_critical` event so we don't wait the full 15-min cron tick for
escalation. Bounded by tier 4. Debounced 60s per event.

## What each role does

### Operator (you)

- Reads `disk_critical` mentions in the SessionStart digest. If you see one,
  check `tail -F /tmp/chump-disk-critical-reactor.out.log` — the reactor
  should be acting. If silent for >2 min after a disk_critical event:
  ```bash
  launchctl print gui/$(id -u)/dev.chump.disk-critical-reactor
  # last exit code should be 0; if KeepAlive bounced, check ThrottleInterval
  ```
- Manual emergency reap (use the same primitives the automation uses, never
  ad-hoc `rm -rf` on shared paths):
  ```bash
  scripts/coord/disk-pressure-reaper.sh --execute --tier 4
  scripts/coord/sccache-reaper.sh --execute            # INFRA-2303
  git worktree prune -v
  ```
- Manual page yourself (idempotent, cooldown-gated):
  ```bash
  scripts/dispatch/operator-recall.sh --condition DISK_CRITICAL --reason "..."
  ```

### Opus (orchestrator)

- On SessionStart, scan the digest's `alerts(30m)` line. If `disk_critical`
  is present in the last 30 min and the reactor's last fire is >5 min old,
  the reactor may be dead — restart it before claiming any heavy work:
  ```bash
  launchctl kickstart -k gui/$(id -u)/dev.chump.disk-critical-reactor
  ```
- Do **not** claim work that triggers a full `cargo build --release` (estimated
  ~3 GB) while free disk is < 20 GB.
- Sub-agent dispatch budget tightens at tier 2+: prefer Sonnet on shell-only
  changes (smaller cargo footprint than full Rust builds).

### Sonnet (per-gap implementer)

- Inherit the parent Opus session's awareness — the SessionStart digest is
  re-emitted to you.
- If you see a `disk_critical` ALERT mid-work, finish your current edit and
  ship — do **not** start an additional `cargo check --workspace` if free
  disk is < 10 GB.
- If the reactor pages the operator (`kind=operator_recall` with
  `condition=DISK_CRITICAL`), stop dispatching new work and emit STUCK with
  reason `disk_pressure_operator_paged`.

### Curator sub-roles (ci-audit, handoff, target, decompose, etc.)

- Each curator's `work-your-lane` loop should check the latest free% before
  picking new work:
  ```bash
  free_pct=$(df -P /System/Volumes/Data | awk 'NR==2 {gsub(/%/,"",$5); print 100-$5}')
  if (( free_pct < 10 )); then
    # pick only docs/markdown gaps; defer Rust/test gaps
  fi
  ```

## Cleanup safety reference (what's reapable, what isn't)

| Path                                            | Safe to nuke? | Why / cost                                     |
|-------------------------------------------------|---------------|------------------------------------------------|
| `~/Library/Caches/Mozilla.sccache`              | ✅ yes        | Cache only; cargo rebuilds (lower hit rate temporarily). Reaper handled by `scripts/coord/sccache-reaper.sh` (INFRA-2303). Always `sccache --stop-server` first. |
| `target/debug/incremental/*`                    | ✅ yes        | Cargo regenerates per-package on next build. Forces incremental rebuild, not full recompile of deps. |
| `target/doc/`                                   | ✅ yes        | Rebuilds on `cargo doc`. Rarely-rebuilt. |
| `target/release/`                               | ✅ yes        | Rebuilds on `cargo build --release`. Infrequent trigger. |
| `~/.cargo/registry/`                            | ✅ yes        | Re-downloaded on next cargo invocation. Small (~1 GB typical). |
| `target/debug/deps/`                            | ⚠ careful    | Active build cache. Nuking forces ~30+ min full rebuild of the workspace. Only at tier 4 RED with no active rustc. |
| `target/debug/build/`                           | ⚠ careful    | build.rs outputs. Nuking forces rerun of all build scripts. |
| Whole `target/` directory                       | ⚠ careful    | Combines all above. Last resort. |
| `/private/tmp/chump-<gap-id>` worktrees         | ⚠ depends     | SAFE if (a) no active lease in `.chump-locks/claim-*.json`, (b) branch is merged or absent on remote, (c) no uncommitted changes. The reaper handles this — don't ad-hoc rm. |
| `.claude/worktrees/agent-*` (Claude SDK)        | ⚠ depends     | SAFE if no active subagent session. Check `find . -mmin -360` for recent edits. |
| `~/.cache/chump-runner/cargo-target/`           | ⚠ careful    | Active chump-runner build cache. INFRA-2188 covers retroactive reap. |
| `.chump-locks/claim-*.json`                     | ❌ never      | Active lease; deleting strands the agent. Use `chump --release` instead. |
| `.chump-locks/ambient.jsonl`                    | ❌ never      | Live event stream. Rotated by `ambient-rotate` cron. |
| `.chump/state.db`                               | ❌ never      | Canonical gap registry. |
| `~/.chump/oauth-token.json`                     | ❌ never      | OAUTH credentials. |

## Active-lease protection (universal rule)

**Never reap a directory listed under `paths:` in any open
`.chump-locks/claim-*.json`.** The pre-commit hook (RESILIENT-026) enforces
this on commits, but reapers must enforce it on their own — they do not go
through git.

Reaper-side check (already implemented in `disk-pressure-reaper.sh` and
`stale-worktree-reaper.sh`):

```bash
for claim in .chump-locks/claim-*.json; do
  jq -r '.paths[]?' "$claim" 2>/dev/null
done | grep -qx "$candidate_path" && skip "active lease"
```

## Why `--no-verify` is not the answer

When disk pressure causes a commit hook to fail (rare — pre-commit barely
touches disk), `--no-verify` skips the very hooks that protect active
leases. Don't. Instead:

1. Free disk first (reaper at appropriate tier).
2. Re-run the commit; let the hook pass cleanly.
3. If the hook is structurally broken, file a gap and bypass narrowly:
   `git commit -m "msg" -m "Off-Rails-Bypass: <reason>"` (emits audit trail).

## Failure-class taxonomy (where to file follow-up gaps)

- **Bytes leak (a new path consuming GB)** → INFRA gap with `RESILIENT` tag,
  evidence = `du -sh` output, mention which tier should cover it.
- **Wiring break (event fires but no consumer)** → INFRA gap with `RESILIENT
  P0`, evidence = `grep -rn '"kind":"<event>"' scripts/`, mention the
  missing consumer's expected path.
- **Pre-action planner miss (action committed without checking disk)** →
  META-128 sub-slice or follow-up gap, evidence = the action class and the
  estimated cost.
- **False positive (reaper nuked something it shouldn't)** → INFRA P0
  RESILIENT, evidence = ambient `kind=<reaper>_reaped` event and proof of
  the active claim/lease.

## Operator escalation ladder

| Step | Action                                                              | Triggers next step if... |
|------|---------------------------------------------------------------------|--------------------------|
| 1    | `disk_critical` ambient event emitted                                | always proceeds          |
| 2    | reactor invokes `disk-pressure-reaper.sh --execute --tier <up>`      | post-reap free% < threshold |
| 3    | `operator-recall.sh --condition DISK_CRITICAL`                       | operator does not act in 30 min |
| 4    | `chump fleet pause --reason disk_critical` (manual operator)         | fleet stays paused until step 5 |
| 5    | Operator runs manual reap, restarts fleet                            | done                     |

## References

- INFRA-2304 — this gap (reactive wiring)
- INFRA-2303 — sccache + incremental reaper (the bytes side)
- INFRA-2188 — chump-runner cargo-target growth (separate cache path)
- META-128 — disk-aware fleet (pre-action planning)
- INFRA-626 — operator-recall pager
- INFRA-1471 — disk-pressure-reaper tier ladder
- INFRA-1349 — target-dir-reaper
- `scripts/lib/disk-check.sh` — `fleet_paused_disk_critical` SLO pauser
