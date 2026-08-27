# Lease collision audit — INFRA-1602 double-claim (2026-05-17)

INFRA-1608 (RESILIENT). See `docs/process/CLAUDE_GOTCHAS.md` →
"atomic-claim-collision" for the operator-facing known-error-class entry.

## Evidence

Ambient digests captured across multiple `PreToolUse` hook fires on
2026-05-17 showed INFRA-1602 with **two simultaneous live leases**:

| Lease file | expires_at |
|---|---|
| `claim-infra-1602-26392-1778986903.json` | 07:02:09Z |
| `claim-infra-1602-47300-1778986751.json` | 06:59:35Z |

Both were within their TTL window at the time of observation — a genuine
double-claim, not a stale-lease artifact.

## Root-cause classification

The gap description hypothesized four candidates: (a) a race window in the
`try_claim_gap` CAS, (b) NATS-KV vs. file-lock divergence, (c) mixed claim
paths, (d) orphan resurrection. Investigation of the actual claim code
(`crates/chump-atomic-claim/src/atomic_claim.rs::run_claim`) found the real
cause is closest to **(a), but not where the gap description assumed**:

- `chump-coord::CoordClient::try_claim_gap` (crates/chump-coord/src/lib.rs)
  **is** CAS-correct — it uses NATS-KV `create()`, which fails with
  `AlreadyExists` for the loser. That primitive is only exercised when
  `CHUMP_NATS_URL` is set (the opt-in push tier, see CLAUDE.md § Push
  routing). It is not the default path.
- The default, always-on path is the **file-lease path**:
  `check_gap_id_uniqueness` scans `.chump-locks/*.json` for a live lease
  with the same `gap_id`, and `run_claim` calls it once, early (INFRA-1970
  gate), *before* worktree creation, gitdir repair, and the NATS
  dual-write — several seconds of work. The lease file itself is only
  written afterward, in step 7b.
- **There was no exclusion around that gap.** Two `chump claim INFRA-1602`
  invocations starting within that multi-second window each see an *empty*
  `.chump-locks/` for that gap_id at check time, each pass, and each later
  write their own `<session>.json` lease naming the same `gap_id` — this is
  a textbook check-then-act (TOCTOU) race, not a CAS failure, because there
  was no CAS on the file-lease path at all.
- (b)/(c)/(d) were ruled out: `nats_dual_write` returned no conflict signal
  in the surrounding ambient window (consistent with NATS being unconfigured
  for at least one of the two sessions), and both lease files carry
  `taken_at` timestamps close enough together (< 3 minutes, both within
  their own fresh TTL) to be explained by the race window above rather than
  an orphan resurrection.

## Why `lease_overlap` never fired

`lease_overlap` existed in `EVENT_REGISTRY.yaml` (emitter listed generically
as `chump-coord`) but had no emission call in the file-lease path — the only
place a collision could have been *detected* (the INFRA-1970 gate) treats a
collision as a hard failure (`claim_duplicate_gap_blocked`) but only catches
it when the check runs *after* the competing lease already exists on disk.
In the observed collision, both checks ran *before* either lease existed, so
neither session's INFRA-1970 gate ever saw a competitor — nothing fired.

## Fix

`crates/chump-atomic-claim/src/atomic_claim.rs`:

- `acquire_gap_claim_mutex` / `GapClaimMutexGuard` — an `O_CREAT|O_EXCL`
  marker file per gap_id (`.chump-locks/.claiming-<gap>.lock`), used as an
  atomic test-and-set mutex. No new crate dependency; works on any POSIX
  filesystem. Stale locks (holder crashed mid-critical-section) are
  reclaimed after 30s; waiters back off up to 5s before giving up.
- `find_competing_session` — refactored out of `check_gap_id_uniqueness` so
  the winner's session id is available as structured data, not just an
  error string.
- `run_claim` step 7b now: acquires the mutex, re-checks
  `find_competing_session` **one more time** immediately before the lease
  write, and holds the mutex through both the file write (7b) and the
  state.db write (7c). If the re-check finds a competitor, the claim emits
  `lease_overlap` and bails instead of writing a second lease.

This closes the actual race window (early-check → late-write) rather than
tightening the early check, which would not have helped — the early check
was never the last line of defense.

## Test coverage

`crates/chump-atomic-claim/src/atomic_claim.rs` (`mod tests`):

- `gap_claim_mutex_serializes_two_racing_sessions` — two threads race for
  one gap; asserts exactly one winner and exactly one lease file survives.
- `gap_claim_mutex_serializes_high_concurrency` — 50 concurrent claimants
  on one gap; asserts exactly one winner, 49 losers, zero double-claims.
- `gap_claim_mutex_reclaims_stale_lock` — a backdated marker file is
  reclaimed promptly rather than blocking for the full timeout.

Runnable via `scripts/ci/test-atomic-claim-collision.sh`.

## What this does NOT fix

Cross-machine races where one session claims via the NATS push path and
another claims via the pure-offline file path on a different machine
sharing no filesystem are still only protected by `nats_dual_write`'s
conflict check when NATS is configured on both sides. This is the same gap
CLAUDE.md's "Push routing" section already documents as opt-in; INFRA-1608
scope was the always-on file-lease path, which is where the INFRA-1602
collision actually happened.
