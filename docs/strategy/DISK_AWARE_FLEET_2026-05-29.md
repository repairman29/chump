# Disk-Aware Fleet Architecture — 2026-05-29

> Status: design-call doc. Implements META-128 umbrella. Sub-gap coverage:
> C1 (this doc), C2 (inventory daemon), C3 (launchd plist), C4 ([DISK_COST_MODEL.yaml](../process/DISK_COST_MODEL.yaml)),
> C5–C7 (CLI + claim integration + scaler), C8 (multi-node routing, Bet 5 unblock).
>
> Operational reference: [CLAUDE_GOTCHAS.md §Worktree disk hygiene](../process/CLAUDE_GOTCHAS.md#worktree-disk-hygiene)
> · [OPERATOR_PLAYBOOK.md §Disk hygiene](../process/OPERATOR_PLAYBOOK.md#disk-hygiene)

---

## 1. Today's evidence — the gap is already biting us

The fleet does not know how much disk space it needs before it takes an action.
Five evidence points from 2026-05-29 alone:

| Evidence | Impact |
|---|---|
| META-123 cascade hit 98% disk utilisation | Fleet paused; operator manually reaped 16 GB |
| Wave 1 dispatch concern: 6–12 GB burst per integration cycle | infra-watcher curator gated on this before dispatching |
| INFRA-2188: `cargo-target-reaper` misses `~/.cache/chump-runner` | Second leak class, discovered only after the 98% event |
| INFRA-2181 (reaper post-ship trigger) fires AFTER the burst | Emergency cleanup happens after the crisis, not before |
| Operator pings about disk multiple times in a single session | Manual oversight is the only safety net today |

The root pattern: **chump reacts to disk pressure** (operator reap → emergency mode → fleet pause) rather than planning for it. Every action that touches disk — worktree claim, cargo build, integration cycle, parallel dispatch — is taken without any pre-check against available headroom.

This document defines the architecture that inverts that pattern: every disk-consuming action consults a planner before proceeding.

---

## 2. The 4-layer architecture

### Layer 1 — Per-node disk inventory daemon

**Component:** `chump-disk-inventory-daemon` (new Rust binary, `crates/chump-disk-inventory`; or Phase 1: extend infra-watcher).

The daemon polls every 30 seconds:

- `df -k` — total / free / used for the filesystem hosting each consumer path
- `du -sk` for known consumer paths: `/tmp/chump-*`, `~/.cache/chump-runner`, `/tmp/chump-coord-linux-build*`, `~/.cargo/target/`, worktree roots

It writes a snapshot to `~/.chump/disk-inventory.json` and (when NATS is available) publishes to `chump.disk.inventory.<node-id>`. Node identity comes from `hostname` + `~/.chump/node-id.txt`.

The snapshot shape:

```json
{
  "ts": "2026-05-29T...",
  "node_id": "macbook-m4",
  "filesystem": { "total_gb": 228, "free_gb": 42, "used_pct": 82 },
  "consumers": [
    { "path": "/tmp/chump-*",            "used_gb": 4.2 },
    { "path": "~/.cache/chump-runner",   "used_gb": 1.8 },
    { "path": "~/.cargo/target",         "used_gb": 12.3 }
  ],
  "available_headroom_gb": 38
}
```

`available_headroom` = `free_gb` minus a configurable reserve (`CHUMP_DISK_FLOOR_GB`, default 5 GB).

### Layer 2 — Action cost model

**Component:** [`docs/process/DISK_COST_MODEL.yaml`](../process/DISK_COST_MODEL.yaml) (C4 deliverable, shipped with this doc).

A YAML file mapping action classes to average and p95 disk cost estimates. Seeded from today's session measurements; maintained by the observability curator via a rolling log at `~/.chump/disk-cost-observed.jsonl`.

Example entries:

| Action class | avg_gb | p95_gb |
|---|---|---|
| `chump_claim_worktree` | 0.05 | 0.12 |
| `cargo_build_debug` | 2.0 | 3.5 |
| `cargo_build_release` | 0.8 | 1.4 |
| `integration_cycle_per_gap` | 1.5 | 2.8 |
| `sonnet_dispatch_with_worktree` | 2.5 | 4.0 |

A companion script (`scripts/dev/measure-disk-cost.sh`) runs an action, measures delta, and appends to the rolling log. The observability curator lane owns auto-tune updates.

### Layer 3 — Pre-action disk check (`chump disk plan`)

**Component:** New CLI subcommand (C5).

```bash
chump disk plan <action-class> [--count N] [--node NODE-ID]
```

Returns a JSON struct:

```json
{
  "status": "OK",
  "projection": {
    "free_now_gb": 42.1,
    "cost_gb": 2.0,
    "free_after_gb": 40.1,
    "threshold_gb": 5.0
  },
  "alternative": null
}
```

Status values:

- **OK** — proceed; `free_after_gb >= threshold_gb`
- **WAIT** — free headroom tight; suggest reap or delay (`free_after_gb < 15 GB`)
- **REFUSE** — hard block; `free_after_gb < threshold_gb` (default 5 GB)

Callers:

- `chump claim` — calls `disk plan chump_claim_worktree` before worktree add
- `chump fleet up N` — calls `disk plan sonnet_dispatch_with_worktree --count N`
- The META-124 integrator daemon — calls `disk plan integration_cycle_per_gap` before dispatching each wave

**Bypass:** `CHUMP_DISK_PLAN_BYPASS=1` — emits `kind=disk_plan_bypassed` to `ambient.jsonl` for audit. Hard refuses are never silent.

### Layer 4 — Adaptive fleet scaler + multi-node routing

**Component:** Extensions to `chump fleet up` and `chump fleet auto-scale` (C7), and `chump-coord assign` daemon (C8).

**Single-node adaptive scaler (C7):**

- `chump fleet up N` refuses if `disk plan sonnet_dispatch_with_worktree --count N` returns REFUSE; reports max-safe-N instead
- `chump fleet auto-scale` cron-fires every 5 min:
  - SCALE DOWN when `available_headroom_gb < 20`
  - SCALE UP when `available_headroom_gb > 60` AND ship-rate healthy (per INFRA-518 criteria)
  - Emits `kind=fleet_scale_change` with `reason=disk_headroom` to `ambient.jsonl`

**Multi-node routing (C8 — Bet 5 unblock):**

When `CHUMP_NATS_URL` is set and multiple nodes publish disk inventory, `chump-coord assign` extends the work subject with disk metadata:

```
chump.work.<priority>.<class>.<node-with-disk-headroom>
```

Workers advertise capabilities including current headroom; the assign daemon routes `sonnet_dispatch_with_worktree` gaps preferentially to nodes with `available_headroom_gb >= 30`. Per-node disk-pause: a node at `< 5 GB free` refuses new claims but other nodes continue.

---

## 3. The 4-wave migration plan

### Wave 1 — Foundation (parallel-safe, no blockers)

| Gap | Deliverable | Notes |
|---|---|---|
| C1 | This document | Done |
| C2 | `chump-disk-inventory-daemon` Rust binary | Phase 1: extend infra-watcher; Phase 2: dedicated crate |
| C3 | launchd plist + install script | KeepAlive=true per INFRA-2182 pattern |
| C4 | `DISK_COST_MODEL.yaml` + measure script | Done (shipped with this PR) |

Outcome: the fleet can see its own disk state and compare it against cost estimates. No behaviour changes yet.

### Wave 2 — Pre-action guard (depends on C2 + C4)

| Gap | Deliverable | Notes |
|---|---|---|
| C5 | `chump disk plan` / `chump disk status` / `chump disk budget` CLI | Reads inventory snapshot + cost model |
| C6 | `chump claim` integration | Hard REFUSE before worktree add |
| C7 | `chump fleet up` + `auto-scale` disk-aware | Scaler respects disk dimension |

Outcome: the fleet cannot accidentally burst past the floor. Operator no longer needs to guard manually.

### Wave 3 — Multi-node routing (depends on Bet 5)

| Gap | Deliverable | Notes |
|---|---|---|
| C8 | `chump-coord assign` disk-headroom routing | NATS subject extension; Bet 5 hardware decision unblocks |

Outcome: work routes to the node with room. One node low does not stop the fleet.

### Wave 4 — Auto-tune (ongoing, observability curator)

The observability curator reads `~/.chump/disk-cost-observed.jsonl` and updates `DISK_COST_MODEL.yaml` entries whose `observed_n` is large enough to trust. A follow-up gap tracks this lane assignment.

---

## 4. Success criteria

| Criterion | How to verify |
|---|---|
| Zero ENOSPC fleet crashes from chump-driven work | Ambient stream: no `kind=disk_enospc` events for 7 days |
| Pre-claim refusal fires correctly when `free < 5 GB` | `chump disk plan` unit test + integration test against synthetic inventory fixture |
| Fleet scaler adapts before disk crisis | Simulate `available_headroom_gb = 18`; verify auto-scale drops fleet size |
| Operator surface answers "can I run X" in <1s | `time chump disk plan cargo_build_debug` < 1s cold |
| Multi-node routes to headroom-rich node | NATS envelope inspection shows node-id matches highest-headroom node |
| Cost model stays current | `observed_n` grows; `last_updated` field refreshes on curator auto-tune pass |

---

## 5. Open questions for operator

1. **Floor threshold** — 5 GB free (drafted) vs 10 GB? A larger floor is more conservative and reduces burst capacity on machines with 256 GB total. Current machines: 228 GB SSD. Recommend 5 GB for now; revisit when Bet 5 hardware is confirmed.

2. **Auto-scale cron cadence** — every 5 min (drafted) vs every 1 min? Five minutes means up to 5 min of unnecessary fleet load after a disk spike. One minute is more responsive but adds cron noise. My read: 5 min is fine until we have more data.

3. **Disk-watcher as dedicated curator vs extend infra-watcher** — fits META-127 productization vision; dedicated curator is cleaner but a new process to maintain. My read: extend infra-watcher in Wave 1, split to dedicated curator when the daemon hits 500+ LOC or gains a distinct alerting SLO.

4. **Cost model maintenance model** — observability curator owns updates (drafted) vs fully automatic auto-tuning with no human gate? Auto-tune is convenient but could silently inflate estimates if a one-time outlier dominates the rolling log. My read: auto-tune within operator-visible bounds (mean ± 2σ cap); values outside cap require explicit operator approval.

5. **Pre-claim refusal UX** — hard REFUSE (operator must reap manually) vs offer auto-reap inline? Auto-reap (run `cargo-target-reaper` + `stale-worktree-reaper` before retrying) is convenient but adds 30–120s to the claim path. My read: offer auto-reap as opt-in flag (`chump claim --auto-reap-on-low-disk`); default is hard REFUSE with a helpful message pointing to the reaper scripts.

---

*Cross-links:*
- [META-128](../gaps/META-128.yaml) — umbrella gap, full 8-child breakdown
- [DISK_COST_MODEL.yaml](../process/DISK_COST_MODEL.yaml) — C4 cost estimates (consumed by `chump disk plan`)
- [CLAUDE_GOTCHAS.md §Worktree disk hygiene](../process/CLAUDE_GOTCHAS.md#worktree-disk-hygiene)
- [OPERATOR_PLAYBOOK.md §Disk hygiene](../process/OPERATOR_PLAYBOOK.md#disk-hygiene)
- [INFRA-518](../gaps/INFRA-518.yaml) — fleet scaling gate (disk dimension is additive)
- [INFRA-2125](../gaps/INFRA-2125.yaml) — cargo-target-reaper (disk plan can trigger on-demand)
- [INFRA-2181](../gaps/INFRA-2181.yaml) — reaper post-ship trigger (sibling; disk plan is the pre-action companion)
- [INFRA-2188](../gaps/INFRA-2188.yaml) — cargo-runner cache leak (inventory daemon catches this class structurally)
- [META-121](../gaps/META-121.yaml) — Bet 5 hardware decision (unblocks C8)
- [META-124](../gaps/META-124.yaml) — integration cycle daemon (explicit `chump disk plan` call adds safety guard)
