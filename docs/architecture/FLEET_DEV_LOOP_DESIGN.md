---
doc_tag: design
owner_gap: FLEET-14
last_audited: 2026-04-25
---

# FLEET dev loop — design note

**Scope:** how to develop and test FLEET-006/007/008 on a single dev machine
before any cross-machine deployment. **Not** an implementation plan — this
note picks the dev primitives, the test approach, and the starting gap.

**Background.** The
[multi-agent stress harness](INFRA-042-MULTI-AGENT-REPORT.md) (INFRA-042,
2026-04-25) confirmed empirically that the file-based lease primitive
(`.chump-locks/<session>.json`) has **no atomic CAS** — N=4 / N=8 concurrent
agents all "win" the same gap. The mutex today is caller-side via
`gap-preflight.sh` + the optional `chump-coord` NATS layer (which exists in
`crates/chump-coord/` but is not yet on `PATH`). FLEET-007 is the path to a
real distributed mutex; this note scopes how to build it without standing up
a Pi cluster first.

## 1. Dev loop: Docker NATS, no Pi cluster

The cheapest credible NATS we can develop against is a single container:

```bash
docker run -d --name chump-nats -p 4222:4222 -p 8222:8222 nats:latest -js
# JetStream enabled (-js) is required for KV buckets used by chump-coord.
# 8222 is the monitoring HTTP port; useful when debugging.
docker logs -f chump-nats   # tail server logs
docker stop chump-nats && docker rm chump-nats   # tear down
```

This matches the production assumption (`CHUMP_NATS_URL=nats://127.0.0.1:4222`,
already the default in `chump-coord`) and lets us iterate on the Rust client
without networking complications. Cross-machine transport (Tailscale, NATS
leaf nodes, fleet topology) is **explicitly deferred** — none of FLEET-006/007/008
require it for correctness; they require it for *deployment*.

**Loopback principle.** Until a FLEET gap *needs* a second machine to verify
its acceptance criteria, we test on `127.0.0.1`. That keeps the dev loop
under 5 seconds per iteration and avoids confusing distributed-systems bugs
with environment bugs.

## 2. Test approach: `async-nats` + `serial_test`

The `chump-coord` crate already depends on `async-nats = "0.47"` and
`serial_test = "3"` (dev-dep). Pattern for FLEET-007 distributed-lease tests:

1. **Pre-test:** assert NATS reachable (`CoordClient::connect_or_skip`); skip
   the test with a logged warning if not, so CI without Docker still passes.
2. **Hermetic bucket names:** every test uses `format!("test.gaps.{}", uuid)`
   so concurrent test runs don't collide on the same KV bucket.
3. **`#[serial]`** on tests that share a bucket name (cheaper than
   per-test cleanup).
4. **Race assertions:** spawn N tokio tasks that all call `try_claim_gap`
   concurrently; assert exactly one returns `Ok(true)` and N-1 return
   `Ok(false)`. This is the property the file-based primitive lacks
   (per INFRA-042) and the property NATS KV `create` provides natively.
5. **TTL assertions:** claim, sleep past TTL, assert another agent can claim.
   Use a short TTL (1–2s) in tests via the existing
   `CHUMP_GAP_CLAIM_TTL_SECS` env override.

**CI integration:** add a `nats` service container to the relevant
GitHub Actions job (or guard the test module behind a `#[cfg(feature =
"nats-integration")]`), so tests skip cleanly when no broker is available.

## 3. Recommended start: FLEET-007 first

Of the three open FLEET-006/007/008 gaps, **FLEET-007 (distributed leases)** is
the right starting point:

| Dimension | FLEET-006 (ambient stream) | FLEET-007 (distributed leases) | FLEET-008 (work board) |
|---|---|---|---|
| Testable in isolation | Hard — needs subscriber and publisher coordination, easy to false-pass | **Yes** — single property: "exactly one agent gets the lease" | Medium — needs producers, consumers, fitness scoring |
| Failure mode if broken | Lossy observability (annoying) | **Silent duplicate work** (the bug INFRA-042 documents) | No work claimed (visible) |
| Already prototyped | No | **Yes** (`crates/chump-coord/src/lib.rs` — KV `create`-based atomic claim already implemented; just not in PATH or wired into `gap-claim.sh`) | No |
| Unblocks others | FLEET-008 reads from it | **Closes the highest-cost race in the system** | Depends on 006 and 007 |
| Acceptance criteria scope | Bridges file → NATS, both directions | "Two agents cannot claim simultaneously" — one assertion | Multi-gap |

The FLEET-007 description in `docs/gaps.yaml` even names the "two agents
cannot claim the same gap simultaneously" criterion that the INFRA-042
report identifies as the single most important missing property in today's
system. Most of the work is already done in `chump-coord` — what remains is
(a) wire `chump-coord claim` into `scripts/gap-claim.sh` (the call site at
lines 76–91 already exists but is `command -v`-skipped), (b) add the
distributed-mutex integration test, and (c) ship `chump-coord` as a binary
on the standard build PATH.

FLEET-006 (ambient stream → NATS) follows naturally: once the lease-side
event surface is stable, mirroring `ambient.jsonl` is mechanical.

## 4. Out of scope for this note

- Cross-machine NATS topology (leaf nodes, Tailscale routing) — FLEET-013.
- Fleet-wide capability/role assignment — FLEET-009/010.
- Migrating existing file-based leases to NATS at runtime — staged via the
  graceful-degrade path in `chump-coord` (NATS reachable → use it; not
  reachable → fall back to file leases). No big-bang cutover required.

## 5. Next concrete step (pending nod)

Open FLEET-007 implementation in a fresh worktree. First commit will be
the integration test that asserts the distributed-mutex property against a
local Docker NATS container. Second commit wires
`chump-coord claim` into `gap-claim.sh`. Third commit ships `chump-coord` on
the default cargo `--bin` install path. Each commit is intent-atomic and
ships under the merge queue independently.
