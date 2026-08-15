# LOOP STATE — tick 203 — 2026-08-15T04:10Z

## Ships (git log origin/main --since=3h)
(none — last merge was 3h12m ago: 7f0c16cf INFRA-2123 #3776)

## Open PR queue (cache_query_open_prs)
#3788 RESILIENT-326: lease-reaper idempotency — ARMED auto-merge, BLOCKED 2h41m, all checks green
#3789 CREDIBLE-248: kpi report --agents wiring — ARMED, BLOCKED 2h38m, all checks green
#3790 INFRA-2160: webhook receiver retry — ARMED, BLOCKED 2h30m, all checks green
#3791 EFFECTIVE-412: onboard intent-doc reader — ARMED, BLOCKED 2h12m, all checks green
#3792 ZERO-WASTE-041: prune orphan worktrees — ARMED, BLOCKED 1h55m, all checks green

## Ambient tail (relevant)
04:05 pr_stuck (pr=3788, reason=armed_not_merging)
04:02 pr_stuck (pr=3789, reason=armed_not_merging)
03:58 pr_stuck (pr=3790, reason=armed_not_merging)
03:41 pr_stuck (pr=3791, reason=armed_not_merging)
03:30 queue_driver_heartbeat (last one — 40 min ago; cadence is 5 min)
02:55 shepherd_heartbeat (last one — 75 min ago; cadence is 30 min)

## Fleet brief (24h)
Ships: 19 | last 1h: 0 | Stalls > 4h: 0 (but 5 PRs BLOCKED 2h+ and climbing)

## Notes
All 5 PRs show statusCheckRollup green. Branch protection unchanged (verified
via cache, fetched_at 04:08). merge queue shows the PRs armed. Nothing merging.

## Inbox
(no unread broadcasts, no open proposals awaiting vote)
