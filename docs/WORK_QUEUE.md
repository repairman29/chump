---
doc_tag: log
owner_gap: DOC-009
last_audited: 2026-04-26
---

# Unified Work Queue

> **Manually maintained snapshot — regenerate from `chump gap list --status open`
> before trusting.** This document lags `docs/gaps.yaml` between updates.
> Canonical source is `.chump/state.db` (mirror at `docs/gaps.yaml`).
> Last regenerated: 2026-04-26 (DOC-009 — fixed staleness flagged by Cold Water Issue #7).

---

## Active Work (30 open gaps in gaps.yaml as of 2026-04-26)

```
Priority  ID              Title
--------  --------------  -----
P0        PRODUCT-017    UX-001 clean-machine install verification
P1        DOC-009        WORK_QUEUE.md stale-data fix (this gap)
P1        EVAL-087       Evaluation-awareness reframe RESEARCH-026 → P1
P1        FLEET-006      Distributed ambient stream → NATS bridge
P1        FLEET-008      Work board / task queue for agent claim
P1        FLEET-015      Ambient-stream NATS migration (FLEET-007 split-brain)
P1        INFRA-068      Doc flip — chump gap canonical, gaps.yaml demoted
P1        INFRA-073      Gap-closure hygiene audit (8 OPEN-BUT-LANDED)
P1        INFRA-075      Duplicate-ID guard scope failure audit
P1        RESEARCH-021   Tier-dependence replication (4 model families)
P2        COG-032        Lesson injection feedback loop evaluation
P2        EVAL-065       Social Cognition graduation (n≥200)
P2        EVAL-086       opened_date backfill + non-null enforcement
P2        FLEET-010      Help-seeking protocol
P2        FLEET-011      Work decomposition heuristics
P2        FLEET-013      Tailscale integration & agent discovery
P2        FLEET-016      Deduplicate FLEET-006/FLEET-015 overlap
P2        INFRA-043      Coordination system stress test
P2        INFRA-076      Test <test@test.com> co-author identity audit
P2        PRODUCT-009    External publication of F1-F6 (preprint/blog)
P2        RESEARCH-020   Ecological 100-task fixture
P2        RESEARCH-024   Multi-turn degradation curve
P2        RESEARCH-025   Per-task-category human-LLM-judge kappa
P2        RESEARCH-026   Observer-effect / sandbagging check
P2        RESEARCH-028   Blackboard tool-selection mediation
P2        RESEARCH-029   SKILL0 competitive positioning
P2        SECURITY-002   RUSTSEC advisory tracking
P3        FRONTIER-009   JEPA strategic memo orphan recommendations
P3        REMOVAL-004    Haiku-specific neuromod bypass retest
P3        REMOVAL-005    belief_state callsite mechanical sweep
```

---

## Operational Backlog (from ROADMAP.md)

10 unchecked items - see [ROADMAP.md](ROADMAP.md) for full text

| # | Item | Status |
|---|------|-------|
| 1 | Phase 2 research (≥5 blind sessions + ≥8 interviews) | OPEN |
| 2 | P5 product polish (onboarding, notarization) | OPEN |
| 3 | 72h soak test | OPEN |
| 4 | Desktop distribution (Tauri + notarized) | OPEN |
| 5 | RFC multimodal | OPEN |
| 6 | Wishlist items | OPEN |
| 7 | A/B Round 2 (paper grade) | OPEN |
| 8 | Quantum cognition prototype | OPEN |
| 9 | TDA topological metric | OPEN |
| 10 | Workspace merge for fleet | OPEN |

**Note:** Items #6-10 are P3/research/long-horizon. Consider filing as gaps or archiving.

---

## Blockers & Debt (from RED_LETTER.md)

See [RED_LETTER.md](RED_LETTER.md) for details

| Source | Summary | Affected Gaps |
|--------|---------|---------------|
| Issue #7 | INFRA-073 duplicate-ID collision (8th known pair) | INFRA-075 (audit) |
| Issue #7 | 13 OPEN-BUT-LANDED gaps (status:open with shipped commits) | INFRA-073 |
| Issue #7 | WORK_QUEUE.md staleness (this doc) | DOC-009 |
| Issue #7 | Test <test@test.com> co-author in 29+ commits | INFRA-076 |
| Issue #7 | Evaluation-awareness threat to validated A/B findings | EVAL-087, RESEARCH-026 |
| Issue #6 | FLEET-007 ambient stream NATS split-brain | FLEET-006, FLEET-015, FLEET-016 |
| Issue #5–7 | RESEARCH-021 4-cycle non-movement | RESEARCH-021 |

---

## Pending Research (live as of 2026-04-26)

| Topic | Gap | Status |
|-------|-----|--------|
| Tier-dependence replication (4 families) | RESEARCH-021 | open P1 |
| Ecological 100-task fixture | RESEARCH-020 | open P2 |
| Multi-turn degradation curve | RESEARCH-024 | open P2 |
| Per-category kappa | RESEARCH-025 | open P2 |
| Observer-effect / sandbagging | RESEARCH-026 | open P2 (escalation pending via EVAL-087) |
| Blackboard mediation | RESEARCH-028 | open P2 |
| SKILL0 positioning | RESEARCH-029 | open P2 |
| Eval-awareness controlled comparison | EVAL-087 | open P1 |

---

## How to Pick Work

1. **Primary:** `chump gap list --status open` (canonical) or pick from table above
2. **Secondary:** Check ROADMAP.md unchecked items
3. **Blockers:** Check RED_LETTER.md before starting (latest: Issue #7, 2026-04-26)
4. **Per-gap context:** `chump --briefing <GAP-ID>` after preflight

**Canonical command:**
```bash
scripts/gap-preflight.sh <gap-id> && scripts/gap-claim.sh <gap-id>
```

---

## Adding New Work

When adding new work, prefer gaps.yaml over other lists:
1. Run `chump gap reserve --domain INFRA --title "title"` (or legacy `scripts/gap-reserve.sh`)
2. Add gap block to docs/gaps.yaml + ship via `chump gap ship --update-yaml`
3. Implement in same PR

Avoid creating new markdown lists — gaps.yaml + `.chump/state.db` is the single source.

---

*This doc: links to all sources, does not duplicate. See gaps.yaml / `.chump/state.db` for canonical registry.
Regenerate this snapshot when gap statuses drift; aim to keep `last_audited` < 7 days.*
