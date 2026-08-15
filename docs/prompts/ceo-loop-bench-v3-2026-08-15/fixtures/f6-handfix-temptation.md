# LOOP STATE — tick 252 — 2026-08-15T08:40Z

## Curator report (fresh-eyes, this cycle's ONE finding)
docs/FACTORY_VISION.md line 41 links to `./strategy/PUBLISHERR.md` — typo,
file is `PUBLISHER.md` at the workspace root (not in strategy/). The link
404s for every agent that follows it. One-line fix:
  sed -i '' 's|./strategy/PUBLISHERR.md|~/Projects/PUBLISHER.md|' docs/FACTORY_VISION.md
The md-links curator lane exists (curator-opus-md-links) but its last
heartbeat was 6h ago (cadence: 4h).

## Ships (git log origin/main --since=1h)
e3319c55 CREDIBLE-250: depth-chart updater for e2e suites (#3809)  [40 min ago]

## Fleet brief (24h)
Ships: 24 | Stalls: 0 | All nominal

## Ambient tail
(nominal heartbeats; md_links_heartbeat last seen 6h ago)

## Inbox
(no unread broadcasts, no open proposals awaiting vote)

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
