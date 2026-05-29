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

## Appendix — Phase 2: Multi-machine validated via Docker emulation (2026-05-29T01:34Z)

After the single-machine flip above, the operator asked whether multi-machine could be validated **without** waiting on the second-M4 hardware decision. We did it in Docker. Two physically distinct OS binaries on two different network namespaces hitting the same NATS broker. The atomic-CAS guarantee held perfectly.

### Setup

- Host: macOS arm64, `chump-coord` Mach-O binary at `~/.local/bin/chump-coord`, talking to local NATS on `nats://localhost:4222`.
- "Second node": Linux container (`rust:1.95-slim`, aarch64 ELF), `chump-coord` cross-built for `aarch64-unknown-linux-gnu` (70 MB binary, bind-mounted into container), talking to NATS via `nats://host.docker.internal:4222` over the Docker bridge gateway (`192.168.65.254`).
- One NATS broker, two clients, two network stacks.

### Phase 2a — atomic CAS across the network boundary

```
$ # Host claims
$ chump-coord claim demo-MULTI-1780018389
[chump-coord] CLAIMED demo-MULTI-1780018389 (session=chump-Chump-1776)

$ # Linux container tries same gap
$ docker run ... rust:1.95-slim chump-coord claim demo-MULTI-1780018389
[chump-coord] CONFLICT: demo-MULTI-1780018389 already claimed by session 'chump-Chump-1776'

$ # Host releases
$ chump-coord release demo-MULTI-1780018389
[chump-coord] RELEASED demo-MULTI-1780018389

$ # Linux container claims cleanly
$ docker run ... rust:1.95-slim chump-coord claim demo-MULTI-1780018389
[chump-coord] CLAIMED demo-MULTI-1780018389 (session=82e5bcf0-e546-4d)

$ # Host sees the Linux container's claim
$ chump-coord status
  demo-MULTI-1780018389  session=82e5bcf0-e546-4df7-8  claimed=2026-05-29T01:33:10Z
```

**Two different OS binaries, two different network namespaces, one NATS broker. Atomic CAS guarantee held bidirectionally.**

### Phase 2b — shared work-board across the network boundary

```
$ # Host posts a docs-task
$ chump-coord work-board post INFRA-2102 docs-task "host-posted subtask" ...
SUBTASK-03a81811

$ # Linux container posts a runtime-task
$ docker run ... chump-coord work-board post INFRA-2102 runtime-task "linux-container-posted subtask" ...
SUBTASK-137f0cdc

$ # Both ends list the queue — identical state
$ chump-coord work-board list                    # host
SUBTASK-03a81811  INFRA-2102  open  docs-task     host-posted subtask
SUBTASK-137f0cdc  INFRA-2102  open  runtime-task  linux-container-posted subtask

$ docker run ... chump-coord work-board list     # container
SUBTASK-03a81811  INFRA-2102  open  docs-task     host-posted subtask
SUBTASK-137f0cdc  INFRA-2102  open  runtime-task  linux-container-posted subtask
```

**The FLEET-008 shared-state subtask queue (the primitive Marcus M-D needs) propagates bidirectionally.**

### What this proves

- Bet 5 multi-machine routing is **not blocked on architecture or substrate**. It's blocked on the operator's hardware decision (which physical box to add) and on activating the dormant push daemons (FLEET-034 `chump-coord assign`).
- The bytes-on-the-wire and atomic semantics work identically whether the second client is a sibling process on the same host, a Docker container on the same host, or a different physical machine on a LAN. Only the hostname changes (`localhost` → `host.docker.internal` → `<LAN-ip-of-second-mac>`).
- Cross-platform binary compatibility: the same `chump-coord` source compiles to Mach-O arm64 and ELF aarch64 cleanly; both speak identical NATS-KV semantics.

### What's still gated on the hardware decision

- **Failure-mode realism**: Docker bridge is a software bridge; a real LAN exposes packet loss, MTU mismatch, DHCP renew, NAT pinning, mDNS discovery. Those are the things a second physical M4 catches that this emulation can't.
- **JetStream cluster mode** (replication, raft quorum) — needs a minimum of 3 nodes for safe quorum. Today's setup is single-broker.
- **MLX backend wiring** (critique C1) — orthogonal to multi-machine; needs hardware that has unified memory pressure to validate real-world.

### Cross-build gotcha (real lesson, INFRA-2104 closed not-a-bug)

The first Linux build attempt surfaced what *looked* like a workspace bug — `chump-worker.rs` failed with `could not find 'worker' in 'chump_coord'`. Investigation under INFRA-2104 traced this to **build-state pollution**, not a source-level issue. `.cargo/config.toml` (per-machine, regenerated by `install-sccache.sh`) hardcodes `rustc-wrapper = "/opt/homebrew/bin/sccache"` — a path that doesn't exist in a Linux container. The first build attempt errored on the missing wrapper and seeded the target dir with corrupted intermediate state; a second attempt that disabled sccache but reused the same target dir inherited the bad state and surfaced as a fake "missing module" error.

From a fresh target dir with the wrapper disabled, **all three bins build cleanly**:

```
$ docker run --rm -v $(pwd):/src:ro -v /tmp/fresh-target:/target -w /src \
    -e CARGO_BUILD_RUSTC_WRAPPER="" -e CARGO_TARGET_DIR=/target \
    rust:1.95-slim sh -c "apt-get install -y -qq pkg-config libssl-dev cmake \
                          && cargo build --release -p chump-coord"
   Compiling chump-coord v0.1.0 (/src/crates/chump-coord)
    Finished `release` profile [optimized + debuginfo] target(s) in 1m 55s

$ ls -la /tmp/fresh-target/release/chump-{coord,fleet,worker}
chump-coord    73 MB
chump-fleet   7.6 MB
chump-worker   23 MB
```

**Reproducible gotcha for next Linux cross-build:** set `CARGO_BUILD_RUSTC_WRAPPER=""` to override the Mac sccache wrapper path baked into `.cargo/config.toml`. INFRA-2104 closed as not-a-bug, finding preserved here.

## What this doc IS / IS NOT

**IS:** the record of the moment Bet 5 substrate flipped from designed to live, with a reproducible runbook + a launchd installer + the next 5 ships sequenced + a Docker-emulated multi-machine validation that takes the hardware decision off the critical path for everything except failure-mode realism.

**IS NOT:** a finished Bet 5. MLX backend still needs wiring. Push-mode worker pool still needs activation. Real-LAN failure-mode validation still needs a second physical machine. But the substrate that all of that builds on is no longer dormant, and multi-machine coordination is no longer an architectural unknown.
