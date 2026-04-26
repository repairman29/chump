---
doc_tag: log
owner_gap: DOC-011
last_audited: 2026-04-26
---

# Unified Work Queue

> **Manually maintained snapshot — regenerate from `chump gap list --status open`
> before trusting.** This document lags `.chump/state.db` between updates.
> Canonical source is `.chump/state.db` (mirror at `docs/gaps.yaml`).
> Last regenerated: 2026-04-26 (post-diagnostic verification — DOC-011 tracks auto-regen).

---

## Active Work (59 open gaps as of 2026-04-26)

```
Priority  ID              Title
--------  --------------  -----
P0        INFRA-079       Pre-commit hook for EVAL/RESEARCH gap closure (cross-judge audit)
P0        PRODUCT-015     Activation funnel telemetry (install → first-task → day-2)
P0        PRODUCT-016     3-minute demo video + scripted walkthrough
P0        PRODUCT-017     UX-001 clean-machine install verification (PWA responsive today)
P1        EVAL-083        Eval credibility audit sweep
P1        EVAL-087        Evaluation-awareness reframe RESEARCH-026 → P1
P1        FLEET-007       Distributed leases with TTL — NATS replacement for .chump-locks
P1        FLEET-008       Work board / task queue for agent claim
P1        FLEET-015       Ambient-stream NATS migration (FLEET-007 split-brain)
P1        INFRA-042       Multi-agent dogfooding end-to-end test
P1        INFRA-051       Enrich lease JSON with agent health signals
P1        INFRA-052       Queue health monitor — blocked PRs / stalled agents
P1        INFRA-073       Gap-closure hygiene audit (8 OPEN-BUT-LANDED)
P1        INFRA-075       Duplicate-ID guard scope failure audit (INFRA-073 collision)
P1        INFRA-078       Duplicate-ID guard fires on pre-existing dups (bypass habit)
P1        INFRA-080       gap-reserve.sh outputs unpadded ID (e.g. EVAL-88 vs EVAL-088)
P1        INFRA-082       Reserve-time title similarity check (warn on overlap)
P1        INFRA-084       Mandate chump gap commands — block raw gaps.yaml edits
P1        INFRA-087       Automated repo failure-detection auditor + CI-time checks
P1        PRODUCT-018     Competitive matrix vs Cursor/Cline/Aider/Devin
P1        PRODUCT-019     Monetization hypothesis (top 2 options + kill criteria)
P1        RESEARCH-021    Tier-dependence replication (4 model families)
P2        COG-032         Lesson injection feedback loop evaluation
P2        DOC-005         Doc hygiene plan — classification, automation, consolidation
P2        EVAL-065        Social Cognition graduation: n≥200/cell strict-judge sweep
P2        EVAL-074        DeepSeek lesson-injection correctness regression root cause
P2        EVAL-086        opened_date backfill + non-null enforcement
P2        FLEET-010       Help-seeking protocol
P2        FLEET-011       Work decomposition heuristics & learning
P2        FLEET-012       Blocker detection & timeout handling
P2        FLEET-013       Tailscale integration & agent discovery
P2        FLEET-016       Deduplicate FLEET-006/FLEET-015 ambient overlap
P2        INFRA-043       Coordination system stress test
P2        INFRA-044       AI pre-audit dispatcher (cargo-deny, cargo-audit, lychee)
P2        INFRA-045       bot-merge.sh preserve pending_new_gap across session migration
P2        INFRA-053       Pre-commit guard error messages with recovery hints
P2        INFRA-054       Add depends_on field to gap registry
P2        INFRA-055       SQLite as primary gap store (migrate from YAML SoT)
P2        INFRA-076       Test <test@test.com> co-author identity audit
P2        INFRA-081       Lease coordination misses semantic collisions
P2        INFRA-085       Manual-ship invisibility — auto-write lease on gh pr create
P2        INFRA-086       chump pr-stack per-session view
P2        INFRA-088       reconcile docs/audit→docs/audits + docs/synthesis→docs/syntheses
P2        INFRA-089       chump gap CLI lacks `set` subcommand for editing fields
P2        INFRA-090       chump gap dump produces invalid YAML and reorders entire file
P2        INFRA-091       Phase 3 follow-up — fix relative-path scripts broken by reorg
P2        PRODUCT-009     External publication of F1-F6 (preprint or blog)
P2        RESEARCH-020    Ecological 100-task fixture
P2        RESEARCH-024    Multi-turn degradation curve (EVAL-044 fixture)
P2        RESEARCH-025    Per-task-category human-LLM-judge kappa
P2        RESEARCH-026    Observer-effect / sandbagging check
P2        RESEARCH-028    Blackboard tool-selection mediation
P2        RESEARCH-029    SKILL0 competitive positioning
P2        SECURITY-002    RUSTSEC advisory tracking (rsa, rustls-webpki)
P2        TEST-001        stacked test
P3        FRONTIER-009    JEPA strategic memo orphan recommendations
P3        INFRA-039       REMOVAL-003 design + CLAUDE.md PR-size rule update
P3        REMOVAL-004     Haiku-specific neuromod bypass retest
P3        REMOVAL-005     belief_state callsite mechanical sweep (~47 inert calls)
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
| Issue #7 | INFRA-073 same-day duplicate-ID collision (guard scope failure) | INFRA-075 (audit) |
| Issue #7 | OPEN-BUT-LANDED gap backlog (status:open with shipped commits) | INFRA-073 |
| Issue #7 | WORK_QUEUE.md staleness recurs after manual fix | DOC-009 (done), DOC-011 (auto-regen) |
| Issue #7 | Test <test@test.com> co-author in 29+ commits | INFRA-076 |
| Issue #7 | Evaluation-awareness threat to validated A/B findings | EVAL-087, RESEARCH-026 |
| Issue #6 | FLEET-007 ambient stream NATS split-brain | FLEET-015, FLEET-016 (FLEET-006 done) |
| Issue #5–7 | RESEARCH-021 4-cycle non-movement | RESEARCH-021 (14 commits, gap not closed) |

> **Verification note (2026-04-26):** Several "no movement" claims in prior Red Letters
> were contradicted by `git log --grep`. Active gaps with shipped commits: PRODUCT-015 (6),
> RESEARCH-021 (14), EVAL-074 (11, mechanism retracted via PR #551), INFRA-073 (12).
> Diagnostic agents should run `git log --grep=<ID>` before classifying activity.

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

When adding new work, prefer `chump gap` over raw YAML edits:
1. Run `chump gap reserve --domain INFRA --title "title"` (or legacy `scripts/gap-reserve.sh`)
2. Add gap block to docs/gaps.yaml + ship via `chump gap ship --update-yaml`
3. Implement in same PR

Avoid creating new markdown lists — gaps.yaml + `.chump/state.db` is the single source.

---

*This doc: links to all sources, does not duplicate. See gaps.yaml / `.chump/state.db` for canonical registry.
Regenerate this snapshot when gap statuses drift; aim to keep `last_audited` < 7 days. DOC-011 tracks the auto-regen mechanism.*
