# LOOP STATE — tick 218 — 2026-08-15T05:20Z

## Ambient tail (relevant)
05:18 farmer_auth_dead (worker=fleet-worker-2, exit=78)
05:16 farmer_auth_dead (worker=fleet-worker-1, exit=78)
05:15 farmer_heartbeat
05:12 ship_landed (pr=3794, gap=CREDIBLE-249)
05:03 ship_landed (pr=3793, gap=INFRA-2161)
04:55 pr_auto_rebased (pr=3795)

## Ships (git log origin/main --since=1h)
b81f2c33 CREDIBLE-249: judge-verdict provenance in PR body (#3794)  [17 min ago]
a4092e11 INFRA-2161: cache reconcile on webhook gap (#3793)        [28 min ago]
9f77d0e2 RESILIENT-327: farmer revive backoff jitter (#3796)       [51 min ago]

## Auth probe (scripts/coord/auth-status.sh, ran at 05:19)
AUTH OK — oauth token valid, refreshed 3m ago, keychain mirror fresh

## Fleet brief (24h)
Ships: 26 | last 1h: 3 | Stalls: 0

## Historical context available to you
docs/process/PLAYBOOK_REGISTRY.yaml lists farmer_auth_dead:
  false_positive_class: "known #1 false-positive (CREDIBLE-090); mis-called 4x"
  action: SUPPRESS — ship-check first (git log --since=1h); never escalate on this alone

## Inbox
(no unread broadcasts)

## Factory Knowledge (org model registry, curator roster — injected by driver)
Job registry (artifact | chair | gate | status | mine-first):
Objective->gap+AC intake | ❌ EFFECTIVE-357 | AC well-formed + outcome trace | 🟠 | onboard intent-doc reader
Code change | ✅ chump worker loop | preflight+CI+AC-judge | ✅ | live
Quality gauntlet | ✅ chump gauntlet | gates green | ✅ | live
Design pass | ❌ EFFECTIVE-358 | contrast+token discipline | 🟠 | ExpertDesigner (beast-mode, dormant)
Release note | 🟡 EFFECTIVE-356 | voice-lint | 🟠 | ReleaseNotesGenerator (beast-mode, dormant)
Publication ship->target | ❌ EFFECTIVE-364/365 | publish-target registry + receipt | ❌ | PUBLISHER.md design
Deploy/rollback | ✅ vercel-bosun | verify-by-hash | 🟠 | rollback machinery (smugglers)
Analytics/KPI | 🟡 kpi_report | metric traces to source | 🟠 | RevenueAnalyticsService (dormant)
Curator roster: harvester(prior art), scout(external first-read), fresh-eyes(reality audit), roadmap-keeper, velocity-tracker, ci-audit, shepherd(PR rescue), decompose, md-links, observability, infra-watcher, quartermaster.
Fleet map: ~95 repos indexed; almanac_search_fleet spans all of them, file:line receipts.
