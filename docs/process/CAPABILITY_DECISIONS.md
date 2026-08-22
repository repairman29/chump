<<<<<<< HEAD
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
=======
# Capability decisions — tracked toggles

Chump ships some capabilities OFF by default because they act autonomously
on the gap registry (auto-file, auto-block) with no human in the loop, and a
misfire's blast radius is worse than the reactive status quo it replaces.
This doc is the log of those toggles: what they do, why default-OFF, and
when/why an operator flipped one on.

Format per entry: env var, default, what flipping it on does, why it's
gated, and a dated log line every time the default live state changes.

## CHUMP_RCA_REFLEX_ENABLED

- **Default:** OFF (`0`)
- **Where:** `scripts/coord/recurring-gap-pattern-detector.sh` (INFRA-249),
  wired as the `chump-rca-reflex.timer` / `.service` organ (RESILIENT-365).
- **What ON does:** when a cluster of ≥threshold gaps shares a title keyword
  in the detection window, the reflex (a) reserves a META RCA gap with an
  LLM-generated COMMAND/OUTPUT/THEORY/ALT evidence blob, and (b) sets
  `depends_on` on every symptom gap in the cluster to point at the new root
  gap, so the fleet's pickable-gate stops handing out the next symptom until
  the root lands. Idempotent — re-running on the same cluster reuses the
  existing open root gap (dedup by keyword in
  `.chump-locks/pattern-detector-state.json`) rather than filing a
  duplicate.
- **What OFF does:** the detector still runs on its timer, still detects
  clusters, and still emits the human-facing `ALERT`
  (`kind=recurring_gap_pattern`) to `ambient.jsonl` — only the auto-file +
  auto-block side effects are suppressed.
- **Why gated:** this is the first Chump capability that both files gap-store
  writes AND blocks other gaps from being picked, entirely on a timer with no
  human review. A wrong root-cause hypothesis or a keyword collision (e.g. a
  common English word clustering unrelated gaps) would file a bogus RCA gap
  and stall real symptom work behind it. Ship the organ live (so detection
  itself is never dark again — the RESILIENT-365 evidence was 44 symptom PRs
  and 0 root gaps in one night) but keep the autonomous half opt-in until it
  has a track record.
- **Log:**
  - 2026-08-22 — shipped default OFF (RESILIENT-365, first ship). No operator
    has flipped it on yet.
>>>>>>> b3133f33 (RESILIENT-365: wire RCA reflex as a live organ + LLM evidence + symptom depends_on blocking)
