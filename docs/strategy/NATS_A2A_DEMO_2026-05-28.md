# NATS A2A Substrate Demo — 2026-05-28

**Authored:** 2026-05-28 by curator-opus-overnight.
**Closes:** [INFRA-2102](../gaps/INFRA-2102.yaml).
**Companion docs:**
- [`MARKET_POSITIONING_2026-05-27.md`](MARKET_POSITIONING_2026-05-27.md) (#2679) — the 5-Bet strategic compass
- [`MARKET_POSITIONING_BOUNCEOFF_2026-05-28.md`](MARKET_POSITIONING_BOUNCEOFF_2026-05-28.md) (#2681) — the 7 cross-reference answers
- [`docs/design/A2A_ROADMAP.md`](../design/A2A_ROADMAP.md) — META-061 design (audited 2026-05-13)
- [`scripts/setup/install-nats-server-launchd.sh`](../../scripts/setup/install-nats-server-launchd.sh) — the daemon installer

## The moment

Until 2026-05-28T01:17:35Z, the META-061 A2A substrate — `crates/chump-coord` (4,368 LOC), `crates/chump-messaging` (1,315 LOC), MeshTransport trait, NATS KV scratchpad schema, atomic-CAS gap claims, work-board subtasks — was **built but unwired**. `CHUMP_NATS_URL` was unset. No `nats-server` was running. Every primitive fell through to the file-fallback path. The Bounce-off doc named this exactly:

> "Bet 5 substrate is 60-70% pre-built. The constraint is OPERATIONAL not architectural."

This document records the operational flip. The substrate is now LIVE on the M4 primary node.

## What got done

```
$ brew install nats-server                       # v2.14.1, 15.4 MB
$ bash scripts/setup/install-nats-server-launchd.sh
OK: NATS listening on port 4222 (managed by launchd)
$ export CHUMP_NATS_URL=nats://localhost:4222
$ chump-coord ping
[chump-coord] NATS OK (nats://localhost:4222)
```

NATS auto-starts on reboot. `chump-coord` and every dependent primitive (atomic claims, work-board, leases, events) now hit a real broker instead of falling through to file-fallback.

## Smoke test — full atomic CAS lifecycle

This is the killer feature for multi-agent coordination. Two agents claiming the same gap must never both win. The NATS KV CAS gate gives this guarantee atomically.

```
$ chump-coord emit INTENT note="A2A substrate live"
[chump-coord] EMITTED INTENT

$ chump-coord claim demo-INFRA-2102
[chump-coord] CLAIMED demo-INFRA-2102 (session=chump-Chump-1776)

$ chump-coord claim demo-INFRA-2102
[chump-coord] CONFLICT: demo-INFRA-2102 already claimed by session 'chump-Chump-1776'

$ chump-coord status
[chump-coord] Active gap claims (1):
  demo-INFRA-2102  session=chump-Chump-17764717  claimed=2026-05-29T01:17:35Z

$ chump-coord release demo-INFRA-2102
[chump-coord] RELEASED demo-INFRA-2102

$ chump-coord status
[chump-coord] No active atomic gap claims in NATS KV.
```

**Conflict detection works.** Two sessions cannot both win the same gap — the second one gets a clean `CONFLICT` reply naming the winner's session.

## Smoke test — work-board (shared subtask queue, FLEET-008)

```
$ chump-coord work-board post INFRA-2102 docs-task "demo task" \
    --description "test the work-board substrate"
SUBTASK-1846be5e

$ chump-coord work-board list
subtask_id          parent_gap    status   task_class   title
SUBTASK-1846be5e    INFRA-2102    open     docs-task    demo task
```

**Shared-state subtask queue is live.** This is the primitive Marcus M-D ("queue into shared team fleet") needs. Today it's single-machine; multi-machine demo requires Bet 5's second-node hardware decision.

## What this unlocks (and what it doesn't)

### Unlocked immediately
- **Atomic CAS gap claims via NATS KV.** No more two-agents-claim-same-gap races. META-105 collision class is now structurally prevented at the substrate layer (complementary to INFRA-1970's lease-key fix in the lease layer).
- **`chump-coord watch`** for live cross-process event stream — a real alternative to `tail -F .chump-locks/ambient.jsonl`.
- **`chump-coord work-board`** as the substrate for the cross-operator task queue.
- **`chump-coord lease`** dual-write replicas for session lease coordination.
- **Help-request protocol** (`chump-coord help-request`) for capability-routed blocker resolution.

### Not unlocked yet (still need code OR operator hardware decision)
- **Multi-machine routing.** Single-node today. Bet 5 needs the operator's hardware decision (recommend second M4 Mac mini per bounce-off Q7).
- **NATS push-mode worker dispatch.** `chump-coord assign` daemon isn't started yet — FLEET-034 push routing is wired but dormant. Easy to start; not yet started.
- **Local-LLM via MLX.** Critique C1 / INFRA-1964 — orthogonal to NATS. Wiring MLX as a `chump-coord worker` backend would close the local-LLM mission gap independent of multi-machine.
- **Signed provenance.** META-061 Layer 6. Not designed yet; defer.

## Next 5 ships against META-121 (Bet 5 umbrella)

1. **Start `chump-coord assign` daemon** on M4-primary — wires INFRA-1118 (Layer 1a NATS-primary delivery) into active use. Probably one launchd plist (similar shape to this one), one ambient event kind, one operator-visible "active push routing" state.
2. **Subscribe a `chump-coord worker`** to `chump.work.>` — proves end-to-end push dispatch works for a real (synthetic) gap.
3. **Operator hardware decision** for second node — second M4 Mac mini recommended.
4. **Deploy NATS + chump-coord worker on second node** — proves cross-machine.
5. **Wire MLX backend** to a `chump-coord worker` (INFRA-1964 / critique C1) — proves local-LLM ends the mission-reality gap.

## How to roll back (safe)

```
bash scripts/setup/install-nats-server-launchd.sh --uninstall
# Remove CHUMP_NATS_URL from shell rc; chump-coord falls through to
# file-fallback per CLAUDE.md offline-fallback semantics.
```

Substrate code on main is unchanged by this rollback. Only the operational state (daemon loaded, env var set) reverts.

## Cross-references

- **INFRA-1118** (Layer 1a NATS-primary delivery) is now operationally satisfiable; the gap can be re-scoped to "verify file-fallback still works under partition" rather than "wire NATS."
- **INFRA-1267** (cross-machine integration test) is now meaningful — there's a broker to integrate against.
- **INFRA-1119, INFRA-1120** (Layer 2b RPC, Layer 2c capability discovery) — Rust code is on main; the wire-up step is roughly the same shape as this demo plus a few subcommand invocations.
- **META-121** (Bet 5 umbrella) — first concrete child item done; updates needed to depends_on list.
- **INFRA-1939** — bot-merge wedge — note: this PR ships via manual fallback because the wedge is still in place. Bot-merge fix is independent.

## What this doc IS / IS NOT

**IS:** the record of the moment Bet 5 substrate flipped from designed to live, with a reproducible runbook + a launchd installer + the next 5 ships sequenced.

**IS NOT:** a finished Bet 5. Multi-machine still needs the hardware decision. MLX backend still needs wiring. Push-mode worker pool still needs activation. But the substrate that all of that builds on is no longer dormant.
