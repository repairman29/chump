# Release Automation & Persistent Queue Plan

**Date:** 2026-04-24  
**Status:** Planning phase  
**Owner:** Chump infrastructure team  
**Goal:** Implement three-layer automation for releases and CI throughput

---

## Executive Summary

Current bottlenecks:
1. **Manual releases** — requires human to create git tags
2. **Sequential CI** — single GitHub runner, 20+ min test runs
3. **Stalled queue** — PRs get stuck when checks fail; requires manual intervention

Solution: Three-layer automation
1. **Crate publishing** — conventional commits → auto-version-bump → auto-publish
2. **Distributed execution** — farm nodes (Mabel+) run tests in parallel
3. **Queue health** — auto-rebase stale PRs, alert on stalls

Expected outcome: 1-2 PRs/day → 5-10 PRs/day through queue; CI time 20min → 5min.

---

## Layer 1: Release Cadence (INFRA-SYNTHESIS-CADENCE)

### Current State
- 10 workspace crates
- Live only in monorepo (no crates.io presence)
- Manual version management
- Manual publish process

### Phase 1: Audit (Effort: s)
**Work:** Inventory crates → publish/internal/dead decision

Gap: **INFRA-046** — Audit workspace crates

### Phase 2: Dependency Modernization (Effort: m)
**Work:** Update deps, remove unused, pass security audit

Gap: **INFRA-047** — Modernize dependencies

### Phase 3: Release Automation (Effort: m)
**Work:** Wire in release-plz, conventional commits → auto-publish

Gaps:
- **INFRA-048** — Integrate release-plz
- **INFRA-049** — CI dry-run gate

### Phase 4: First Publish (Effort: s)
**Work:** Publish leafmost crate as 0.1.0

Gap: **INFRA-050** — Publish first crate

---

## Layer 2: Distributed Execution (FLEET-006-013)

Already gaps filed:
- FLEET-006: NATS client integration (m, 3-4 days)
- FLEET-007: Capability declaration (s, 1-2 days)
- FLEET-008: Work assignment listener (m, 3-4 days)
- FLEET-009: Help-seeking protocol (m, 3-4 days)
- FLEET-010: Ambient stream integration (s, 1-2 days)
- FLEET-011: WebSocket push transport (m, 3-4 days, P2)
- FLEET-012: E2E test (m, 3-4 days)
- FLEET-013: Continuous deployment pipeline (s, 1-2 days)

Expected outcome: Test suite 20min → 5min; CI throughput 1-2 → 8-10 PRs/day

---

## Layer 3: Queue Health (INFRA-QUEUE-HEALTH)

Gaps:
- **INFRA-051** — Queue health monitor (s, 1-2 days)
- **INFRA-052** — Auto-rebase on stale (s, 1-2 days)
- **INFRA-053** — Webhook notifications (xs, <1 day)

Expected outcome: Stalled PRs auto-detected, auto-rebased, user alerted

---

## Timeline

### Week 1: Foundation
- INFRA-046: Audit workspace crates
- INFRA-047: Modernize dependencies
- INFRA-051-053: Queue health monitoring

### Week 2-3: Release Automation
- INFRA-048: release-plz integration
- INFRA-049: Dry-run gate

### Week 3-6: Distributed Farm (parallel)
- FLEET-006-013 (3-4 weeks)

### Week 7: Publish
- INFRA-050: First crate publish

---

## Success Criteria

- All 10 crates audited & categorized
- Zero RUSTSEC advisories, MSRV declared
- release-plz wired, dry-run gate active
- Leafmost crate published @ 0.1.0
- FLEET agents running on Mabel + 1 other
- Test execution: 20min → 5min
- Queue health: Auto-detect & rebase stalled PRs

