# Capability decisions log

Tracks opt-in flags that gate a *new enforcement capability* — a check that
used to be advisory (warn-only) or absent, now made real, but ratcheted
behind an env var until the fleet has run it in observation mode long enough
to trust the false-positive rate. One entry per flag. When a flag flips to
default-on, update its entry rather than deleting it — the history of why a
gate was cautious is as load-bearing as the gate itself.

## `CHUMP_VERIFY_LIVE_BLOCKING` (PEER-VERI-08, INFRA-3655)

- **Default:** off (unset / any value other than `1`).
- **What it does:** when a PR's proof AC bullet (`PROVEN-BY <unit|kind=event|URL>`)
  fails `check_live_outcome` (crates/chump-verify/src/pr_ac_coverage.rs), the
  PR-close path treats that as a **blocking** `Miss` instead of falling through
  to `CHUMP_AC_GATE_ADVISORY`'s warn-and-continue behavior. Non-proof AC
  misses are unaffected by this flag — they keep their existing
  advisory/blocking behavior either way.
- **Why gated:** `check_live_outcome` shells out to `systemctl` / reads
  `ambient.jsonl` / curls a URL at PR-close time. Until the proof-AC
  synthesizer (same gap, AC#1 — `maybe_inject_proof_ac` in
  `pr_ac_coverage.rs`) has run in production for a stretch and the
  false-positive rate on synthesized targets is known, a blocking failure on
  a flaky probe (systemd unit mid-restart, ambient log rotated, transient
  network blip) could wedge a otherwise-good PR. Advisory-first lets the
  fleet observe `ac_coverage_proof_miss` / `ac_coverage_live_blocking`
  ambient volume before it can hold a merge.
- **Ratchet plan:** flip to default-on once a full week of
  `ac_coverage_proof_miss` events on synthesized (not hand-written) proof
  bullets shows a near-zero false-positive rate (spot-checked against the
  actual unit/event/endpoint state at the time of the miss).
- **Where it's read:**
  `crates/chump-verify/src/pr_ac_coverage.rs::score_against_bullets`.
- **DEPTH tier:** D2 (opt-in enforcement flag, single-crate blast radius,
  fails closed to the pre-existing advisory path when unset).

## Related capabilities

- `CHUMP_AC_GATE_ADVISORY` — the pre-existing advisory-vs-blocking switch for
  the AC-coverage gate as a whole (CREDIBLE-178). `CHUMP_VERIFY_LIVE_BLOCKING`
  only carves proof-bullet misses out of that switch's fail-open path; it
  does not replace it.
- `CHUMP_AC_JUDGE_LLM` — the LLM judge overlay (EFFECTIVE-373). Explicitly
  cannot override a proof bullet's verdict (CREDIBLE-281) — the live-outcome
  check is the only authority for proof bullets, blocking or not.
