# Durable-Fix Doctrine — No Band-Aids (CREDIBLE-105)

> **One line:** When something is broken, fix the thing that's broken — not your
> path around it. A workaround that unblocks only *you* while leaving the breakage
> in place for the next agent is a **band-aid**, and a band-aid as a *terminal*
> action is forbidden.

A band-aid is not primarily a resilience problem — it's a **credibility** problem.
It makes something *look* fixed when it isn't. That's the same failure family as
[`REALITY_CHECK.md`](./REALITY_CHECK.md) (a detector firing is a SIGNAL, not an
OUTCOME) and Verify-before-alarm: **a thing looking done is not the same as the
thing being done.** This doctrine makes that the law for *fixes*, not just alarms.

---

## Origin: the 2026-06-05 sccache incident (the canonical band-aid)

A session's `cargo` build started failing with `sccache: encountered fatal error`
on third-party crates. The session's **first instinct was to set
`RUSTC_WRAPPER=`** — disable sccache — to get *its* build through.

That would have:

1. **Left the real bug in place** for every other agent. The dead sccache server
   was wedging **every fleet worker's Rust build**, not just this one. The
   band-aid unblocks one session and silently strands the other ~N.
2. **Masked the root cause.** The actual bug was two **unlocked**
   `scripts/coord/sccache-reaper.sh --execute` runs racing the live cache (fired
   by `disk-pressure-reaper` during the disk crisis), pruning entries out from
   under in-flight builds → a 2-daemon split-brain on port 4226.

The operator caught it (*"WTF FIX THE SERVER DOG"*). The durable fix was: diagnose
the split-brain, kill the racing reapers, collapse to one clean daemon, **and file
the real fix** (gap **RESILIENT-112**: the reaper needs a concurrency lock +
atime-skip). Result: one healthy listener, zero cache errors,
the whole fleet's builds flowing again.

`RUSTC_WRAPPER=` was the band-aid. Fixing the server was the durable fix. The gap
between them is this doctrine.

---

## The rule

**Fix the cause, not your path around it.** Before you apply *any* workaround, it
must pass the test below. If it can't, the workaround is not allowed as your final
move — keep going until you've fixed the cause or filed it.

### The pre-workaround test (3 questions)

1. **Does this fix the cause, or hide it?**
   If you're routing *around* the failure — disabling the tool, skipping the gate,
   `--no-verify`, retry-until-green, hardcoding/mocking past it, `|| true`,
   `2>/dev/null` on an error you didn't diagnose — you are **hiding** it, not
   fixing it.

2. **Who inherits the breakage?**
   If the honest answer is "every other agent / the next worker / the next
   session / future-me," it is a **fleet-wide** band-aid. Escalate to the real
   fix *now* — the blast radius is not yours to silently pass on.

3. **Is the deferral visible?**
   A workaround is acceptable *only as a bridge* (see carve-out) and *only* if
   **(a)** the real fix is filed as a gap with the root-cause writeup, **AND**
   **(b)** the workaround emits an audit signal (ambient event or bypass trailer).
   **Silent workarounds are never acceptable.**

---

## Band-aid smells (the ban-list)

If you reach for one of these, stop and run the test:

- **Disabling a tool to get past its failure** instead of fixing the tool
  (`RUSTC_WRAPPER=`, commenting out a linter, `SKIP=hook`).
- **`--no-verify` / `CHUMP_PREFLIGHT_SKIP=1` as a habit** rather than a single
  documented exception. (`--no-verify` is already called out in `CLAUDE.md` as
  "the reason most regressions ship.")
- **`|| true` / `2>/dev/null`** swallowing an error you have not diagnosed.
- **Retry-until-green** on a *deterministic* failure — treating a logic bug as a
  flake. (A real flake is reran per `KNOWN_FLAKES.yaml`; an undiagnosed failure is
  not a flake.)
- **Hardcoding or mocking** past a real integration failure so the surface looks
  green.
- **"Works on my machine" path-scoping** that leaves the *shared* resource broken.
- **Restart/kill to clear a wedge WITHOUT filing the durable fix** for *why* it
  wedged. (Killing the sccache zombie was necessary; it was only a durable fix
  *because* RESILIENT-112 captured the missing lock.)
- **Reporting a mechanism as active before verifying it is active.** "The loop is
  running" with no `/loop` job set; "tests pass" when the test binary never ran
  (`exit 0` ≠ "the assertions executed" — read the `running N tests` line);
  "it's deployed" before you checked the target. This is the same lie as a
  band-aid, pointed at status instead of code.

---

## When a bridge IS allowed (the carve-out)

Pragmatism is real: sometimes you must unblock *now* and cannot land the full fix
in the same motion. A workaround is a legitimate **bridge** — never a
destination — when **all three** hold:

1. **You diagnosed the cause.** You can name *what* is broken and *why*, not just
   "it's flaky."
2. **The real fix is filed** as a gap, with the root-cause writeup and a rough
   shape, *before* you move on.
3. **The bridge is observable** — it emits an ambient event or carries a bypass
   trailer (see [`BYPASS_TRAILER_SCHEMA.md`](./BYPASS_TRAILER_SCHEMA.md)), so the
   deferral shows up in the audit log instead of hiding.

Example (correct bridge): NATS is down, so `chump --release` can't reach the
NATS-KV claim. The release still clears the JSON + state.db (the legs it *can*),
the NATS-KV shell-out is **best-effort and non-fatal**, and the KV claim TTL-expires
on its own. The limitation is documented in the code and the behavior is logged —
it's a bounded, visible bridge, not a silent swallow.

---

## When you DO fix it (durable-fix obligations)

1. **Fix the root cause, not the proximate symptom.** Ask "why" until you hit the
   thing whose fix prevents recurrence. (sccache symptom: "my build fails." Cause:
   "the reaper has no concurrency lock.")
2. **Leave a regression guard.** A test, a lock, an invariant, a CI gate — whatever
   makes silent recurrence impossible. A fix with no guard is a fix with a
   half-life.
3. **If you can only bridge now, file the real fix first.** The gap *is* the
   durable fix's placeholder; without it the bridge becomes permanent by neglect.

---

## Self-check (paste-ready)

Before declaring something fixed or working, answer out loud:

```
[ ] Did I fix the cause, or route around it?
[ ] If I routed around it: is the real fix FILED + is the bridge OBSERVABLE?
[ ] Who inherits the breakage if I stop here? (if "everyone else" → not done)
[ ] Did I VERIFY the mechanism is active, or am I narrating that it is?
[ ] Is there a regression guard so this can't silently come back?
```

If any box is empty, you are not done.

---

## Case study: the docs/gaps YAML-rewrite cycle (EFFECTIVE-219)

The 2026-06-05 RESILIENT-110 ship attempt hit a variant of the same lie in a
different guise: it kept getting forced into a `docs/gaps/<ID>.yaml` rewrite
cycle mid-ship. The proximate cause looked like "some background daemon is
deleting the YAML mirror between reserve and claim" — a band-aid response
would have been to just keep re-running `chump gap dump --per-file` to paper
over the churn every time it happened, never asking why the file kept
disappearing.

The durable-fix investigation (EFFECTIVE-219) surveyed every drift-repair
surface that touches `docs/gaps/*.yaml` — `scripts/coord/gap-doctor.py`
safe-sweep, `crates/chump-gap-store/src/sync.rs`,
`crates/chump-gap-store/src/maintenance/doctor.rs` — and found that **none
of them ever deleted an orphaned mirror file**; bucket 4 (YAML present, no
`state.db` row) was always ALERT-only. The actual root cause of the
YAML-rewrite churn was upstream and had already been fixed by **ZERO-WASTE-020**
(#3215, landed 2026-07-20): `chump gap reserve` used to write the per-file
mirror at reserve time and only commit the DB row afterward, leaving a real
window where a sibling sweep could see "YAML with no DB row yet" and treat it
as bucket 4. ZERO-WASTE-020 retired the reserve-time YAML write entirely —
state.db is the sole write target at reserve, closing the window at the
source instead of teaching every reader to tolerate it.

EFFECTIVE-219's own contribution was defense-in-depth for the *general*
class, not just this one instance: `gap-doctor.py safe-sweep` gained an
opt-in `--prune-orphans` mode that deletes bucket-4 files, but only after a
**fresh** `state.db` re-check performed immediately before each delete — if
a row has appeared since the sweep's snapshot, the file is rewritten from
state.db instead of deleted, and a `kind=yaml_orphan_pruned` ambient event
records every actual delete. STATE WINS is now enforced in code, not just
asserted in this doc. See `scripts/ci/test-yaml-orphan-prune-state-aware.sh`
for the regression guard.

---

## Case study: the AUTH_DEAD-spam sequence (RESILIENT-113)

The 2026-06-05 AUTH_DEAD-spam incident is a sharper teaching example of the
same lesson as the sccache case study: **agents stop at the first plausible
theory and run with it.** The session shipped three wrong theories before
finding the durable fix — each one a band-aid that would have unblocked *this*
session while leaving the real breakage for the next agent.

**Theory 1 (band-aid, filed as RESILIENT-115 #3089):** "farmer.sh should do a
shallow auth check and tell the operator to work around it." Filed from 4 lines
of source — a surface-level patch that routes *around* the failure instead of
fixing it. The DURABLE_FIX_DOCTRINE.md self-check would have caught this at
theory 1 if the session had actually run it.

**Theory 2 (wrong diagnosis):** "Keychain has no Claude entry." Refuted by
running `security dump-keychain | grep -i claude` — the entries were present
and valid. The session jumped to a Keychain theory without verifying the
premise.

**Theory 3 (wrong diagnosis):** "Rename Keychain service from `Claude
Code-credentials` to `Claude Safe Storage`." Refuted by reading the 24-char
base64 blob — it was Electron's `safeStorage` encryption key, not OAuth tokens.
The session was about to mutate Keychain state based on a misread of the data.

**Theory 4 (the durable fix, RESILIENT-113 #3090):** "`farmer.sh check_auth`
doesn't know about the `api-key` fallback path." Empirically verified: the
check only probed OAuth, so a valid `ANTHROPIC_API_KEY` in `.env` was ignored
and the script reported auth dead. The durable fix taught `check_auth` to try
the API-key path when OAuth is absent, closing the gap at the source instead of
patching around it.

**The lesson:** All four theories were *plausible*. The first three were wrong.
The session shipped each one as a fix without verifying the causal chain — the
same pattern as `RUSTC_WRAPPER=` in the sccache incident. A pre-workaround
self-check at Theory 1 would have forced the session to ask "does this fix the
cause, or hide it?" and "who inherits the breakage?" — and the answer would
have been "every other agent whose auth check silently ignores the API-key
fallback."

**Cross-ref:** Durable fix — [RESILIENT-113 #3090](https://github.com/example/resilient-113/pull/3090).
Band-aid (closed, superseded) — [RESILIENT-115 #3089](https://github.com/example/resilient-115/pull/3089).
Regression guard: `scripts/ci/test-farmer-check-auth.sh`.

---

## See also

- [`REALITY_CHECK.md`](./REALITY_CHECK.md) (CREDIBLE-090) — signal ≠ outcome; the
  alarm-class sibling of this fix-class doctrine.
- [`BYPASS_TRAILER_SCHEMA.md`](./BYPASS_TRAILER_SCHEMA.md) — how a legitimate
  bridge makes itself auditable.
- `CLAUDE.md` / `AGENTS.md` → "Hard rules" — the `--no-verify` rule and the
  one-line pointer to this doctrine.
- `KNOWN_FLAKES.yaml` — the registry that distinguishes a *real* flake (rerun-OK)
  from an undiagnosed failure (band-aid if reran).
