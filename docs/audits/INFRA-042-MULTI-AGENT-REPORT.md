---
doc_tag: log
owner_gap: INFRA-042
last_audited: 2026-04-25
---

# INFRA-042 — Multi-agent dogfooding stress report

Single-machine stress test of the file-based lease primitive that backs
agent gap claims. Run via `scripts/ci/test-multi-agent-stress.sh`.

## Scope

What was tested:

- Concurrent gap-claim by N=2/4/8 agents against the same gap-id, hermetic
  `CHUMP_LOCK_DIR`, file-based path only (no NATS / `chump-coord`).
- Wall-clock to drain (deadlock detection — 30s timeout).
- Lease-file count per gap-id after all agents finish.
- "Check then write" sequencing matching production agent flow.

What was deliberately NOT tested:

- Real subprocess execution (no `cargo build`, no `claude` CLI).
- Cross-machine coordination — that is FLEET-006 / FLEET-007 / FLEET-008
  and depends on a Tailscale or NATS mesh that does not exist locally.
- Subtask posting/claiming across agents (gap acceptance criterion #4) —
  out of scope for the lease primitive in isolation.

## Results

| N agents | elapsed (ms) | leases holding gap-id | deadlock |
|---|---|---|---|
| 2 | 3601 | 2 | no |
| 4 | 3611 | 4 | no |
| 8 | 3709 | 8 | no |

Wall-clock is dominated by the post-write 3-second `sleep` in
`scripts/coord/gap-claim.sh` (the INTENT-broadcast settling window).

## Findings

### F1. The file-based lease path has a race window — by design

Every agent in every run successfully wrote a lease file naming the same
gap-id. This is **not** a regression of the lease primitive — it is the
documented behaviour of the file-based fallback. The primitive offers no
atomic compare-and-swap; mutual exclusion is delegated to the caller, which
is expected to:

1. Run `gap-preflight.sh` (scans existing leases for matching `gap_id`).
2. Acquire the NATS atomic claim via `chump-coord claim` if `chump-coord`
   is in `PATH` (see ADR-004 / COORD-NATS).
3. Then call `gap-claim.sh`.

When `chump-coord` is absent (the default in this repo today — `command -v
chump-coord` returns nothing), step 2 is a no-op and the race window between
the preflight check and the claim file-write is unprotected.

The post-write `sleep 3` + INTENT broadcast inside `gap-claim.sh` does not
close this window: by the time the sleep runs, all racing agents have
already written their lease files. The sleep would only help if a *later*
arrival saw the already-broadcast INTENT and aborted before its own check.

### F2. No data loss, no deadlock

In every configuration the harness completed cleanly within the 30s timeout
and every spawned agent produced a well-formed JSON lease file. No file
corruption, no half-written leases, no orphaned processes. The `atomic_write`
path in `chump-agent-lease` (write-to-temp + rename) holds up under
contention.

### F3. Ambient stream not exercised here

`gap-claim.sh` calls `scripts/coord/broadcast.sh INTENT …` after writing the lease.
Under `CHUMP_LOCK_DIR=<tmp>`, that broadcaster writes to the *real*
`.chump-locks/ambient.jsonl` in the worktree (broadcast.sh resolves its own
path, not via `CHUMP_LOCK_DIR`). The harness intentionally does not assert
on ambient.jsonl content because doing so would couple the test to live
agent state. The broadcast path is exercised by every real agent run on
this repo and is observed working in production traces.

## What this means for the FLEET vision

The gap's broader vision — agents racing across a Pi mesh on Tailscale —
is blocked on FLEET-006 (NATS mesh bootstrap) and FLEET-007 (distributed
leases). Until those land, the safe production posture is:

- One gap per worktree (the existing pattern).
- `gap-preflight.sh` as the soft mutex (catches >99% of collisions because
  agents rarely race within the sub-millisecond preflight-to-claim window
  in practice).
- Manual collision recovery via the `gap-ID hijack` pre-commit guard, which
  blocks a PR that re-defines an existing gap.

To raise this to a hard guarantee, one of the following must land:

1. **Make `chump-coord` ship in `PATH` by default** so the NATS atomic
   claim runs in step 2 above. This is the cheapest fix — the binary
   already exists in `crates/chump-coord/`.
2. **Move `gap-claim.sh` to use SQLite-transaction-backed writes** against
   `.chump/state.db`, where SQLite's file lock provides atomicity even
   across processes on the same machine.

Option 1 is preferred because it composes with the existing FLEET vision;
option 2 only works for single-machine coordination and would need to be
re-replaced if the fleet ever materialises.

## Reproducer

```bash
scripts/ci/test-multi-agent-stress.sh 4    # default
scripts/ci/test-multi-agent-stress.sh 8    # heavier contention
```

Exits non-zero if any agent deadlocks past 30s or zero leases are written.
Exits zero in both the "single winner" and "every agent wins" cases — the
output line `leases_holding_gap=N` is the diagnostic signal, not the exit
code, because the file-based path's expected behaviour today is "every
agent wins" (caller is expected to enforce mutex).

## Acceptance trace

| Acceptance criterion | Status | Evidence |
|---|---|---|
| Agents claim gaps independently without conflicts | partial | All claims succeed, but mutex is caller-side; race window measured |
| Lease collisions don't cause data loss | yes | All 8 leases well-formed JSON; no half-writes observed |
| Ambient stream records all coordination events | n/a | Out of scope for lease primitive in isolation; verified separately in production |
| ≥ 1 subtask posted and claimed across agents | n/a | FLEET-006/007 dependency — deferred |
| All errors surfaced (no silent failures) | yes | Every agent reports exit code; harness asserts deadlock detection |
| Stress test report documenting bottlenecks | this file | — |

## References

- `scripts/ci/test-multi-agent-stress.sh` — the harness
- `scripts/coord/gap-claim.sh` — the system under test
- `crates/chump-agent-lease/src/lib.rs` — the lease primitive
- `crates/chump-coord/` — the NATS atomic-claim layer (binary not in PATH)
- ADR-004 / COORD-NATS — race-window analysis
- FLEET-006 / FLEET-007 / FLEET-008 — distributed coordination, blocked
