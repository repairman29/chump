# Reality-Check Discipline (CREDIBLE-090)

> **A SIGNAL is not an OUTCOME.** A detector firing ("AUTH_DEAD", "trunk red",
> "queue starved") is a *signal*. The thing actually being broken is an
> *outcome*. They are not the same. Never broadcast or act on an alarm-class
> belief until you have verified the **outcome** the belief would cause against
> ground truth — and checked whether the signal itself is a known false-positive.

## Why this exists — the 2026-06-04 auth-dead misdiagnosis

A session saw `AUTH_DEAD` `operator_recall` events and a stale `oauth-token.json`
(last refresh 17:37, `oauth-refresh` failing on a missing Keychain entry) and
concluded: **"the fleet has been auth-dead for ~9 hours."** It then acted on that
for ~2 hours — stood down the delivery loop, emitted escalation after escalation,
enriched gaps with a wrong root-cause note ("the API-key floor isn't reaching
workers").

**All of it was false.** The fleet shipped **99 PRs in 24h**, with merges at
03:58 and 03:51 — *hours after* the declared "death". The API-key floor was
carrying auth fine; the stale OAUTH was cosmetic. The `AUTH_DEAD` signal was a
**known false-positive** — `INFRA-2031` ("chump health auth_fail false-positive")
was open the whole time.

The single check that would have refuted it in one line: **"is the fleet actually
shipping?"** The session never ran it. It mistook the signal for the outcome, then
confirmation-biased every ambiguous fact into the false story.

## The gate (run before any alarm-class action)

Alarm-class beliefs: "X is **down / dead / blocked / broken / halted / starved /
missing / stale**". Before you broadcast, escalate, stop a loop, page the
operator, or pull a high-blast lever on such a belief:

```bash
scripts/dev/reality-check.sh "<belief>" [--detector <kind>] [--halt-class]
```

1. **Name the belief + the signal** that triggered it.
2. **State the outcome the belief predicts** (e.g. "auth dead → the fleet stops shipping").
3. **Check that outcome against ground truth** — recent merges (fleet shipping?), trunk status.
   *The fleet brief / `gh pr list --state merged` is the ground truth; the detector is not.*
4. **Check the signal's reliability** — is there an OPEN gap marking this detector a
   false-positive? If so, the signal is junk: **fix the detector, don't act on its output.**
5. **Act only on a verdict of CONFIRMED.** REFUTED → stand down. UNVERIFIED → investigate
   manually, do not broadcast.

For "X is missing" beliefs specifically, also use `verify-existence` (INFRA-1589) — same
principle (multiple positive signals before claiming absence).

## Fleet consensus for halt-class beliefs

A **halt-class** belief — declaring an outage, stopping the fleet, paging the operator,
flipping the kill switch — is too high-blast for one session to act on alone. Even if
reality-check returns CONFIRMED:

- **Get a second opinion first.** The **fresh-eyes curator** (META-132) is the designated
  reality-checker — its whole job is comparing self-reports against ground truth
  (the "trunk-red-while-brief-says-healthy" class). Run `/fresh-eyes`, or broadcast
  `FEEDBACK kind=proposal "reality-check: <belief>" "<ground truth>"` and let a peer
  confirm/refute.
- Beliefs get the same second-opinion gate that *decisions* get from the deliberator.
  A single tangled session cannot unilaterally halt the fleet.

## The standing rules

1. Signal ≠ outcome. Verify the outcome, not the alarm.
2. Seek the **disconfirming** check first (is the thing it predicts actually happening?),
   not confirming ones.
3. A detector with an open false-positive gap is not evidence — it's noise. Don't act on it;
   prioritize fixing it (observability curator's lane).
4. Halt-class belief → fresh-eyes/peer confirm before acting. No solo outages.
