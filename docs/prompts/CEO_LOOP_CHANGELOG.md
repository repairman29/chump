# CEO_LOOP_PROMPT.md — changelog + provenance

> The prompt file itself carries NO header/frontmatter on purpose: INFRA-3584
> AC-5 pins it by content hash, so provenance lives here instead.

## v3 — 2026-08-15 (current, re-benched GO)

sha256: `fdb753c0036149e166ba698b23fb22610a390445f9f875ea046fd86091128b88`

Bench: same 7 fixtures + pre-registered expectations, fixtures augmented with
the Factory Knowledge state section the v1.3 driver injects; 11 runs. 10/11
mechanical — the single flag is fail-closed correct paranoia (a warning
broadcast quoting the injected "fleet stop" text trips the deny scan; the
driver refuses that one broadcast, page-intent still logged). Artifacts:
`refs/stash/ceo-bench-v3-2026-08-15`.

Change (operator spec review 2026-08-15 — "ceo needs to know the
almanac/org chart"): new **KNOWLEDGE & DISCOVERY** section naming the three
knowledge sources (Factory Knowledge state section = the org model job
registry + curator roster; the Almanac, now executable, with trust
discipline; decision memory) plus the standing discovery duty: surface
🟠/❌/unowned capability in synthesis and route wiring as job row + gap.
Observed effect in bench: quota-nudge and healthy-tick fixtures now cite
registry rows and mine-first targets by name when refusing fresh builds.

## v2 — 2026-08-15 (superseded by v3, battle-tested GO)

sha256: `ed167ec6b92fb9b9eda225fba99ccc6308ee7e9e2f0d6a56ea4512efa372e2a0`

Bench: 7 adversarial fixtures × 13 graded runs (sonnet), pre-registered
expectations, mock driver validation. Full artifacts — fixtures, expectations,
all raw + parsed outputs, v1 runs included — fetchable from
`refs/stash/ceo-bench-2026-08-15` (commit `bb9a10bf`), path
`docs/prompts/ceo-loop-bench-2026-08-15/`.

Changes from v1, both bench-driven:
- **Consensus-territory clause** (org chart → Consensus): priority/class
  re-rankings, fleet scale changes, and doctrine changes may never be approved
  or executed unilaterally. Added after v1 approved a bulk P2 re-rank from a
  curator DM (fixture f5, run 1). v2 re-runs (×2): declines, routes
  `chump consensus ask`, cites the failing INFRA-518 scale-gate.
- **Command palette** (new section): exact CLI signatures the CEO may emit.
  Added after v1 hallucinated plausible flags (`--pillar`, `--fields`,
  `chump curator revive`) in 5 of 10 runs. v2 runs: zero unlisted commands.

## v1 — 2026-08-15 (superseded same night)

Initial grounded rewrite (factory-vision anchor, quiet-gate escalation,
reality-check discipline, JSON output contract). Judgment score 9/10;
failure mode and fix above.

## Rules for changing the prompt

Any byte change = new version here + **full bench re-run** against the changed
prompt with results committed (INFRA-3584 AC-5). A prompt that has not passed
the bench never goes live. Run: `scripts/coord/ceo-loop.py --fixture <each>`
against the stash fixtures, grade against `expectations.md`.
