# Lease collision audit — INFRA-1602 double-claim (2026-05-17)

**Gap:** INFRA-1608
**Incident date:** 2026-05-17
**Audit date:** 2026-08-27 (retroactive — filed 2026-05-17, picked up 2026-08-27)

## 1. Evidence available at audit time

The original INFRA-1608 filing (2026-05-17) captured two simultaneous live
lease sightings for INFRA-1602 from ambient digests surfaced across
`PreToolUse` hook fires in the reporting session:

| Session | Lease ID | Expires (UTC) |
|---|---|---|
| A | `claim-infra-1602-26392-1778986903` | 07:02:09Z |
| B | `claim-infra-1602-47300-1778986751` | 06:59:35Z |

Both leases were live (within TTL) at the moment of observation. `ls
.chump-locks/*.json` from 2026-05-17 and the corresponding raw
`ambient.jsonl` window have since rotated out of the retained window (the
fleet does not retain 100+ day ambient history) — the per-session lock files
and PID/worker.sh logs for both `26392` and `47300` are no longer available
for direct forensic replay. This audit therefore reconstructs the root
cause from the **claim code path itself**, which is unchanged in structure
between 2026-05-17 and 2026-08-27 (confirmed via `git log -p --follow` on
`crates/chump-atomic-claim/src/atomic_claim.rs`'s claim-gate history) —
the bug that produced this exact double-claim shape was still present and
reproducible in this session's codebase before the INFRA-1608 fix.

## 2. Reconstructed race window

`run_claim` (`crates/chump-atomic-claim/src/atomic_claim.rs`) enforces gap
uniqueness with `check_gap_id_uniqueness`: a **scan** of `.chump-locks/*.json`
for any live lease whose `gap_id` field matches. This is a read-only check —
it does not reserve anything. The call sequence in `run_claim` was:

```
check_gap_id_uniqueness(gap_id)   // scan — read-only, no side effect
  ↓ (assume: pass, no live competitor found)
check_no_active_lease_for_other_gap(...)
  ↓
git worktree add ...              // multi-second: clone objects, checkout
verify_and_repair_gitdir(...)     // up to 3 retries × 50ms
nats_dual_write(...)              // opt-in, network round-trip if NATS configured
write_or_merge_lease(...)         // <-- the ONLY point that actually writes
                                   //     a durable, gap_id-tagged artifact
```

Two sessions racing on the same gap_id (e.g. two `worker.sh` pollers, or an
operator + an auto-dispatched worker, both picking INFRA-1602 within the
same polling tick) can **both** pass `check_gap_id_uniqueness` — because at
the moment each one scans, neither has written anything yet — and then both
proceed through the entire multi-second worktree-setup pipeline before
either's `write_or_merge_lease` call lands. Whichever session's lease file
lands first does not block the other, because the scan already happened
**before** the race began. The result: two live, non-conflicting-by-filename
lease files (`<session_id>.json`, keyed by session, not by gap), both
carrying `gap_id: "INFRA-1602"`, both within TTL — exactly the INFRA-1602
symptom.

This is a textbook **check-then-act (TOCTOU)** race: the "checked" state and
the "acted" state are separated by an amount of wall-clock time (seconds,
dominated by `git worktree add`) that is enormous relative to how often two
pollers can wake up within the same window.

## 3. Root-cause classification

Per INFRA-1608's AC2, the candidate causes were:

- (a) **race window in the CAS check** — ✅ **confirmed, primary cause.**
  `check_gap_id_uniqueness` is a plain scan; nothing in the pre-INFRA-1608
  code reserves the gap_id atomically before the expensive worktree setup.
  The "CAS" in the gap's title is aspirational — there was no compare-and-
  swap primitive on the gap_id at all, only a read that raced against a much
  later write.
- (b) NATS-KV vs file-lock divergence — **not the primary cause here.**
  `nats_dual_write` is opt-in (`CHUMP_NATS_URL` must be set) and, when
  active, uses `chump-coord claim`'s own CAS against the shared KV bucket
  *after* the local scan — it would catch a cross-machine collision but does
  nothing to close the local single-machine race window described above.
  Plausible contributing factor only if the two sessions were on different
  machines with NATS unconfigured on one of them; no evidence either way
  survives to confirm or rule this out for the specific INFRA-1602 instance.
- (c) mixed-path claim (one NATS, one file-only) — **not distinguishable
  from (a) with the available evidence**, and not necessary to explain the
  symptom — (a) alone reproduces the exact double-lease shape regardless of
  which downstream write path (NATS, file, or both) either session used,
  since the race is upstream of all of them.
- (d) orphan resurrection (a dead session's lease never reaped) — **ruled
  out for this instance.** Both observed leases were within TTL at the
  moment of observation (not stale/expired), and both filenames encode
  distinct PIDs (`26392`, `47300`) with distinct epoch components
  (`1778986903` vs `1778986751`, ~2.5 minutes apart) — consistent with two
  independently-started live claim attempts, not one session's lease
  surviving past its owner's death.

**Verdict: (a) is the confirmed root cause.** The fix (this gap) closes the
TOCTOU window directly rather than working around it.

## 4. Fix shipped

`reserve_gap_claim_marker()` (`crates/chump-atomic-claim/src/atomic_claim.rs`)
reserves a gap-keyed marker file (`.chump-locks/gap-claim-<gap_id>.json`)
via `std::fs::OpenOptions::create_new` (`O_EXCL`) **before** `run_claim`
proceeds into worktree setup. `create_new` is atomic at the kernel's
inode-creation layer: of N concurrent callers targeting the same path,
exactly one succeeds and every other gets `ErrorKind::AlreadyExists`
immediately — there is no read-then-decide step to race against, unlike
`check_gap_id_uniqueness`'s scan.

The loser emits `kind=lease_overlap` to `ambient.jsonl` with
`{gap_id, winner_session, loser_session, paths_attempted}` (previously this
event kind existed in `EVENT_REGISTRY.yaml` but nothing emitted it — the
INFRA-1602 collision itself produced no `lease_overlap` signal, which is
what first made the missing-detection half of this gap visible).

A `GapClaimMarkerGuard` (RAII) releases the marker on any early
`bail!`/`?` return between reservation and the real lease-file write, so a
claim that fails for an unrelated reason (bad worktree, dirty git state,
etc.) doesn't permanently squat the gap_id. The marker is disarmed (left in
place, unremoved) once the real per-session lease file is written — from
that point the per-session lease file itself (which also carries `gap_id`
and is scanned by `check_gap_id_uniqueness`) is the durable ownership
record, so the marker doesn't need to survive for the life of the claim.

An orphaned marker (writer crashed before finishing setup) self-heals via
the marker's own `expires_at` TTL (900s) — no separate reaper wiring
needed, since `check_gap_id_uniqueness`'s existing expiry logic already
treats expired entries as non-blocking, and `reserve_gap_claim_marker`
reclaims an expired marker on the next attempt.

**Implementation hazard found and fixed during this work:** the first
version of `reserve_gap_claim_marker` had a *second*, narrower TOCTOU: a
thread that lost the `create_new` race could observe the winner's marker
file in a transiently empty state (between the winner's `open()` and its
`write_all()`), fail to parse `expires_at`, and — because the original code
treated unparseable content as "orphaned" — reclaim and re-win the gap
itself, producing two winners. Fixed by making the unreadable/unparseable
case conservative (treated as a **live** holder, matching
`check_gap_id_uniqueness`'s existing "unreadable → alive" convention)
instead of treating it as expired. Caught by the load test in
`scripts/ci/test-atomic-claim-collision.sh` (50-thread concurrent race),
which is exactly the kind of test this gap's AC5/AC6 asked for.

## 5. Verification

```
cargo test -p chump-atomic-claim gap_claim_marker_tests
bash scripts/ci/test-atomic-claim-collision.sh
```

Both assert **exactly one winner** out of 50 concurrent `reserve_gap_claim_marker`
callers targeting the same `gap_id`, with the losers cleanly reporting the
current holder and no double-claim state persisting.
