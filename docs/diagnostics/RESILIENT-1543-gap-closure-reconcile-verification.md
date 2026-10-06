# RESILIENT-1543 — gap-closure-reconcile hub verification

## What was checked

`chump-gap-closure-reconcile.{service,timer}` is a **system-level** unit
(installed to `/etc/systemd/system` by `scripts/setup/install-helsinki-atc.sh`,
`User=ubuntu`), not a `systemd --user` unit. On the hub (cuphead):

```
$ sudo systemctl is-active chump-gap-closure-reconcile.timer
active
$ sudo systemctl is-enabled chump-gap-closure-reconcile.timer
enabled
```

The journal shows it firing every 15 minutes all day and actively draining
drift — e.g. at 21:45 UTC on 2026-10-06 it closed a real open-but-merged
ghost:

```
merged-pr-titles: 1 open gap(s) have a MERGED PR titled with their ID — draining
  GHOST RESILIENT-1513: merged PR #5199 (2026-10-06) — gap still open
  CLOSED RESILIENT-1513 done (PR #5199 merged 2026-10-06) — drift resolved
```

So the organ itself is alive and doing its job. AC 1 and 2 were already true
on this hub before this session; no service/timer code changed.

**Stray duplicate found and removed**: a `systemd --user` copy of the same
unit name also existed under `~/.config/systemd/user/`, carrying an invalid
`User=ubuntu` line left over from a prior install attempt (user-session
units cannot set `User=` — `systemctl --user` already runs as the invoking
user, so this failed every run with `Failed to determine supplementary
groups: Operation not permitted`, exit 216/GROUP). Disabled and stopped it
(`systemctl --user disable --now chump-gap-closure-reconcile.timer`) so it
can't be confused with the real, working system-level organ.

## META-108 / META-333 / META-345 class

The reconciler's three passes (`--check-closure-drift`,
`--check-merged-pr-titles`, `--check-already-satisfied`) only catch gaps
whose *own* gap-ID appears in a merged PR title or a worker cycle log. They
structurally cannot catch a gap whose work landed under a **different**
gap-ID with no textual link — exactly what happened here:

- **META-108** ("needs corrective-keyword exception or operator-override")
  — satisfied by **META-937** (PR #4767, `corrective-keyword exception for
  waste-SLO fleet-pause`), a sibling slice of the same umbrella. Confirmed
  live in `scripts/dispatch/_pick_and_claim_gap.py` (`FLEET_REQUIRE_TITLE_SUBSTR`)
  and `scripts/ci/test-corrective-keyword-exception.sh`.
- **META-333** ("instrument remaining audit sub-test scripts with
  [PASS]/[FAIL] markers") — satisfied incrementally across many unrelated
  PRs; verified directly: all 32 `scripts/ci/test-*audit*.sh` scripts now
  emit `PASS`/`FAIL` output (unbracketed `PASS:`/`FAIL:` convention, same
  substance as the AC).
- **META-345** ("secondary heartbeat check for monitor liveness") — **not**
  satisfied; no implementation found, and its declared dependencies
  (META-334, META-343) are still open. This one is correctly still open —
  it isn't a false positive of the already-satisfied class, it's genuinely
  unstarted work.

Both META-108 and META-333 had already been independently flagged
`already satisfied on main` by live cloud-shift dispatches earlier on
2026-10-06 and are now `status: blocked` with notes recommending closure —
`chump gap preflight` correctly refuses them (`already done`), so cloud
shifts are **not** being re-served this specific pair any more. They are
not yet flipped to `status: done` (flipping requires exclusive `state.db`
access, which was contended by the live fleet during this session) — filed
as a narrow follow-up rather than forced through contention.
