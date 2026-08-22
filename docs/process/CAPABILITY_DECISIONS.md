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
