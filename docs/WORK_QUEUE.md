# Unified Work Queue

> Single source of truth for what to work on next. Updated 2026-04-22.

---

## Active Work (13 gaps in gaps.yaml)

```
Priority  ID              Title
--------  --------------  -----
P0        RESEARCH-021   Tier-dependence replication (4 family)
P0        RESEARCH-021   Tier-dependence replication (4 family)
P1        RESEARCH-020   Ecological 100-task fixture
P1        RESEARCH-024   Multi-turn degradation curve
P1        RESEARCH-025   Per-task-category kappa
P1        RESEARCH-026   Observer-effect sandbagging
P1        PRODUCT-009   External publication (F1-F6)
P2        RESEARCH-028   Blackboard tool-selection mediation
P2        EVAL-065      Social Cognition graduation (n≥200)
P2        EVAL-074      DeepSeek lesson-injection regression
P2        INFRA-025     Rust crates publish to crates.io
P2        REMOVAL-003   Remove belief_state module
P2        PRODUCT-014   Discord intent parsing
P3        REMOVAL-004   Haiku neuromod bypass retest
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

| Issue | Summary | Blocked Gaps |
|-------|---------|--------------|
| #4 | Python 3.12 discipline not enforced | Many eval gaps |
| INFRA-006 | vllm-mlx Metal crash not fixed | INFRA related |
| PRODUCT-009 | Closed without acceptance criteria met | - |
| F6 replication | Few-shot exemplar unreplicated | COG-031 lineage |

---

## Pending Research (from CONSCIOUSNESS_AB_RESULTS.md)

| Finding | Status | Gap |
|---------|--------|-----|
| Judge bias (EVAL-042) | pending | EVAL-042 |
| Module attribution (EVAL-043) | pending | EVAL-043 |
| F6: few-shot exemplar | n=1, unreplicated | COG-031 |

---

## How to Pick Work

1. **Primary:** Pick from gaps.yaml `status: open` (above)
2. **Secondary:** Check ROADMAP.md unchecked items
3. **Blockers:** Check RED_LETTER.md before starting
4. **Research:** Check CONSCIOUSNESS pending

**Canonical command:**
```bash
# Pick next available gap
scripts/gap-preflight.sh <gap-id> && scripts/gap-claim.sh <gap-id>
```

---

## Adding New Work

When adding new work, prefer gaps.yaml over other lists:
1. Run `scripts/gap-reserve.sh <DOMAIN> "title"` for new ID
2. Edit docs/gaps.yaml with gap block
3. Commit in same PR as implementation

Avoid creating new markdown lists - use gaps.yaml as single source.

---

*This doc: links to all sources, does not duplicate. See gaps.yaml for canonical registry.*