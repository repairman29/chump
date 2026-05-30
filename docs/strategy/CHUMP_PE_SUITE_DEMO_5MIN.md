# Chump P&E Suite — 5-Minute Demo Runbook

> **Audience:** Marcus (Persona-1 / Hooked IC), external design reviewers, grant readers.
> **Goal:** show the AI P&E team deliberating on a real question in real time —
> not a single-agent feature tour, but a standing team that installs in one command,
> asks curators for input, and surfaces a consensus decision within five minutes.
>
> **Umbrella:** [META-127](../gaps/META-127.yaml) — AI Agent Suite for fleet P&E management.
> **Design doc:** [INSTALLABLE_SUITE_2026-05-30.md](INSTALLABLE_SUITE_2026-05-30.md) (INFRA-2228).
> **Consensus discipline:** [INFRA-2209](../gaps/INFRA-2209.yaml).
> **Status command:** INFRA-2229 (`chump pe-suite status`) — awaiting merge PR #2789.
>
> The `chump consensus` subcommand is **simulated** until META-125 C5 ships.
> Every beat below that calls `chump consensus *` is backed by the synthetic
> fixture in `scripts/demo/chump-pe-suite-demo.sh`.
> Real behavior once META-125 lands will match these surface calls exactly;
> only the subprocess routing changes.

---

## Overview — the five beats

| # | Label | Command surface | Time |
|---|---|---|---|
| 1 | Install | `chump-pe-suite install <repo>` | 0:00 – 0:45 |
| 2 | Status | `chump pe-suite status` | 0:45 – 1:30 |
| 3 | Ask | `chump consensus ask "..."` | 1:30 – 2:00 |
| 4 | Curators reply | FEEDBACK stream printed to terminal | 2:00 – 4:00 |
| 5 | Resolve + pivot | `chump consensus roadmap-pivot` | 4:00 – 5:00 |

Total wall clock: 5 minutes. No network dependency beyond the local NATS broker.
Synthetic fixture ships in `scripts/demo/chump-pe-suite-demo.sh` so the runbook
can be re-run on any machine without a real external customer repo.

---

## Beat 1 — Install (0:00 – 0:45)

### Presenter narration

> "One command. We point it at a repo we have never touched — call it `synthetic-api` —
> and before the prompt returns, a standing P&E team is operational."

### Command

```bash
chump-pe-suite install ~/demo/synthetic-api
```

### What the installer emits (synthetic fixture)

```
[pe-suite] checking substrate... NATS OK, chump-coord OK
[pe-suite] depositing 14 curator role documents → .claude/agents/
  curator-opus-ci-audit.md          ✓
  curator-opus-decompose.md         ✓
  curator-opus-external-collab.md   ✓
  curator-opus-handoff.md           ✓
  curator-opus-harvester.md         ✓
  curator-opus-infra-watcher.md     ✓
  curator-opus-md-links.md          ✓
  curator-opus-observability.md     ✓
  curator-opus-target.md            ✓
  curator-opus-orchestrator.md      ✓
  curator-opus-context-keeper.md    ✓
  curator-opus-scout.md             ✓
  curator-opus-fleet-brief.md       ✓
  curator-opus-policy.md            ✓
[pe-suite] copying 7 loop scripts → .claude/scripts/coord/
[pe-suite] bootstrapping inbox → .chump/inbox/
[pe-suite] wiring NATS subjects chump.curator.*
[pe-suite] emitting kind=suite_installed
[pe-suite] done. 14 curators active. 7 loop scripts armed.
```

### Why this matters (talking points)

- The install is **idempotent** — re-running on a repo that already has the suite
  updates files in place without stomping local edits. The underlying design
  (INFRA-2228) specifies checksum-based diffing so only changed role docs are written.
- The 14 curators map to real job functions: CI health, architecture decomposition,
  external collaboration tracking, handoff coordination, cross-repo harvesting,
  infrastructure watching, doc-link integrity, observability, gap targeting,
  orchestration, context retention, scouting, fleet briefing, and policy (auto-merge
  trust). These are not generic "AI assistants." Each has a named lane, a discipline
  rule set, and a confidence calibration loop.
- Version 1 assumes Chump substrate (NATS, `chump` CLI). Version 1.1 generalizes
  to repos without the Chump layer. The versionable scope split is described in the
  design doc at Section 3.

---

## Beat 2 — Status (0:45 – 1:30)

### Command

```bash
chump pe-suite status
```

### Expected output (INFRA-2229 surface, synthetic fixture)

```
Chump P&E Suite — status as of 2026-05-29T14:32:01Z

REPO     ~/demo/synthetic-api
SUITE    v1.0.0  (installed 00:00:31 ago)

CURATOR                    STATE      LOOP ARMED   LAST HEARTBEAT
───────────────────────────────────────────────────────────────────
ci-audit                   active     yes          just now
decompose                  active     yes          just now
external-collab            active     yes          just now
handoff                    active     yes          just now
harvester                  active     yes          just now
infra-watcher              active     yes          just now
md-links                   active     yes          just now
observability              active     yes          just now
target                     active     yes          just now
orchestrator               active     yes          just now
context-keeper             active     yes          just now
scout                      active     yes          just now
fleet-brief                active     yes          just now
policy                     active     yes          just now

14 / 14 curators active.  Gap queue: 0 open.  Consensus queue: 0 pending.
```

### Talking points

- All 14 show `active` immediately because the install loop emitted
  `kind=curator_heartbeat` for each role as part of the bootstrap sequence.
  In a live repo, heartbeats fire on a 5-minute cadence; a curator that misses
  two consecutive heartbeats is marked `stale` and the orchestrator pages.
- The `LOOP ARMED` column tells the operator which curators have an active
  `launchd` / `systemd` daemon running their loop script. A curator without a
  loop armed still responds to consensus questions but does not self-initiate.
- `Gap queue: 0 open` — the synthetic repo starts empty. In a real repo,
  this would show the existing gap backlog the curators will start triaging.

---

## Beat 3 — Operator asks a question (1:30 – 2:00)

### Presenter narration

> "The team is live. I have a real architectural question about this repo — do we
> ship changes per-PR, or batch them into weekly release cycles? I ask the team.
> I pick 5 curators as a quorum and give them 60 seconds."

### Command

```bash
chump consensus ask \
  "Should we use per-PR ship cycles or batch weekly releases for this repo?" \
  --quorum 5 \
  --timeout 60s \
  --roles ci-audit,target,infra-watcher,harvester,policy
```

### What the command emits

```
[consensus] question registered: CONSENSUS-001
[consensus] routing to 5 curators: ci-audit, target, infra-watcher, harvester, policy
[consensus] quorum: 5 of 5 required. timeout: 60s
[consensus] waiting for FEEDBACK...
```

### Talking points

- `--quorum 5` means all 5 named curators must reply before the aggregator
  resolves. A partial quorum (e.g. `--quorum 3 --of 5`) returns a provisional
  answer if the timeout fires before all replies land.
- The question is free-form natural language. Internally the consensus routing
  layer (META-125 C5) publishes a structured envelope on
  `chump.curator.<role>.consensus_ask` and expects FEEDBACK replies on
  `chump.curator.<role>.consensus_reply`.
- Role selection is explicit here to keep the demo focused. The orchestrator
  curator can auto-select roles when `--roles` is omitted, based on question
  keyword matching against role lane descriptions.

---

## Beat 4 — Curators reply (2:00 – 4:00)

### Presenter narration

> "Watch the curators reply in real time. Each response includes a position,
> confidence score, and rationale. This is the consensus discipline — every reply
> is structured so the aggregator can tally without interpretation."

### Synthetic FEEDBACK stream (printed as replies arrive)

```
─── FEEDBACK from curator-opus-ci-audit ────────────────────────────────────
Position:   per-PR
Confidence: 85%
Rationale:  Per-PR shipping gives CI a clean signal per change. Batch cycles
            mean one green build masks multiple root causes. For this repo,
            where test coverage is sparse, we want per-PR isolation so regressions
            are attributable. A weekly batch would hide 3-5 failure classes
            simultaneously on a bad week.
Cross-ref:  INFRA-2209 (consensus discipline), fleet CI failure taxonomy.

─── FEEDBACK from curator-opus-target ──────────────────────────────────────
Position:   per-PR
Confidence: 72%
Rationale:  Gap targeting assumes per-PR atomicity. Batch cycles break the
            intent-atomic principle: a gap's acceptance criteria spans exactly
            one PR. Batching would require either multi-gap PRs (hard to review)
            or re-filing gaps at batch time (wasted filing overhead). Per-PR
            keeps the gap-to-PR mapping clean.
Cross-ref:  AGENTS.md §"PRs are intent-atomic".

─── FEEDBACK from curator-opus-infra-watcher ───────────────────────────────
Position:   per-PR (conditional)
Confidence: 60%
Rationale:  Per-PR is correct if the merge queue handles throughput. If this
            repo ships >20 PRs/day and the queue becomes a bottleneck, a
            daily-batch window (not weekly) is a reasonable middle path.
            I am flagging this at 60% because throughput data for this repo
            is not yet available — the synthetic fixture has no PR history.
            Recommend revisiting after 2 weeks of observed ship rate.
Cross-ref:  INFRA-2228 §4 substrate dependencies.

─── FEEDBACK from curator-opus-harvester ───────────────────────────────────
Position:   per-PR
Confidence: 90%
Rationale:  Cross-repo harvesting requires stable commit SHAs as anchor
            points for cross-pollination briefs (CP-NNN). Weekly batches
            produce jumbo commits that are hard to pin. Per-PR gives the
            harvester clean primitives to extract and port. Arsenal catalog
            accuracy degrades with batch merges.
Cross-ref:  docs/arsenal/GLOBAL_ARSENAL.md, CP-brief format.

─── FEEDBACK from curator-opus-policy ──────────────────────────────────────
Position:   per-PR
Confidence: 78%
Rationale:  Auto-merge trust is calibrated per-PR via the trust-cliff knob
            (INFRA-1489). Batch cycles would require a new trust model: trust
            across a bundle, not per change. The per-op / per-repo override
            mechanism in policy assumes per-PR granularity. Switching to batch
            would need a policy rework that is not scoped in the current suite.
Cross-ref:  INFRA-1489 (Marcus M-E trust-cliff).
```

### Talking points

- Every FEEDBACK reply follows the INFRA-2209 discipline schema: `Position`,
  `Confidence`, `Rationale`, `Cross-ref`. The aggregator does not need to parse
  free-form text — it reads the structured header block.
- Confidence scores are self-assigned by each curator. False positives from
  over-confident curators feed back into the calibration loop: if a curator
  consistently votes high-confidence on positions that later prove wrong, its
  base confidence is discounted in the aggregator's tally.
- The `infra-watcher` reply at 60% is intentional — it flags missing data
  rather than forcing a high-confidence answer. A curator that inflates
  confidence to achieve consensus is a failure mode the discipline is designed
  to prevent.

---

## Beat 5 — Consensus resolves + roadmap auto-pivots (4:00 – 5:00)

### What the aggregator prints after all replies land

```
[consensus] all 5 replies received in 38s (timeout was 60s)
[consensus] CONSENSUS-001 resolved

QUESTION  Should we use per-PR ship cycles or batch weekly releases?

DECISION  per-PR
VOTES     5 for per-PR / 0 for batch / 0 abstain
WEIGHTED  85% ci-audit + 72% target + 60% infra-watcher + 90% harvester
          + 78% policy = weighted 77% mean confidence

AMBIENT   kind=consensus_decision_emitted  id=CONSENSUS-001  decision=per-PR
          confidence=77  ts=2026-05-29T14:34:39Z

CAVEATS   infra-watcher flagged: revisit if ship rate >20 PRs/day.
          Recommend: schedule a re-ask in 2 weeks with observed throughput.
```

### Roadmap pivot command

```bash
chump consensus roadmap-pivot CONSENSUS-001
```

### Pivot output

```
[roadmap-pivot] reading CONSENSUS-001 decision: per-PR
[roadmap-pivot] scanning open gaps for batch-ship assumptions...
  INFRA-2241 "batch release tooling" — priority was P2 → demoting to P3 (conflicts per-PR decision)
  INFRA-2199 "per-PR auto-merge policy" — priority was P3 → promoting to P1 (aligned with decision)
[roadmap-pivot] 2 gaps re-ranked. emitting kind=roadmap_pivoted.
[roadmap-pivot] done.
```

### Talking points

- `kind=consensus_decision_emitted` is a real ambient event kind, registered in
  `EVENT_REGISTRY.yaml`. Every downstream tool that watches `ambient.jsonl` sees
  the decision automatically — no manual communication step.
- The roadmap pivot is the productized version of what curators do manually today:
  after a decision, re-rank gaps that depend on the outcome. The auto-pivot reduces
  the delay between "team decided" and "queue reflects the decision" from hours to
  seconds.
- The 60% infra-watcher caveat is preserved in the decision output. The curators
  do not suppress minority views in favor of a clean majority read — the operator
  sees the dissent and can act on the re-ask recommendation.

---

## Synthetic fixture

The demo runs entirely against the synthetic repo `~/demo/synthetic-api` created
by `scripts/demo/chump-pe-suite-demo.sh`. No real customer repo is needed for
the first version of this demo. The fixture provides:

- A bare git repo with one commit (`init: synthetic-api demo fixture`)
- A pre-populated `.chump/state.db` with 3 open gaps (for the status command)
- A pre-seeded ambient stream with 5 historic events (for authenticity)
- The 5 FEEDBACK reply payloads above, emitted by the script in sequence with
  a 4-second inter-arrival delay to simulate real curator response time

Run the full 5-beat sequence with:

```bash
bash scripts/demo/chump-pe-suite-demo.sh
```

---

## Cross-references

- **PITCH.md** — see the "Team-tier substrate demo" section added by this gap.
- **DEMO_5MIN.md** — see the "P&E Suite (Marcus M-D)" section added by this gap.
- **ROADMAP_MARCUS.md** — M-D milestone marked DEMOED-BY INFRA-2234.
- **INFRA-2228** — installable suite design doc (the install beat implements this).
- **INFRA-2229** — `chump pe-suite status` CLI (beat 2 uses this surface).
- **INFRA-2209** — consensus discipline (the FEEDBACK schema in beat 4 follows this).
- **META-125 C5** — `chump consensus` subcommand (simulated here until it ships).
- **META-127** — umbrella gap for the full P&E suite effort.

---

*Filed under INFRA-2234. Last updated 2026-05-29.*
