# INFRA-8714 — closed not-a-bug: P0 budget is not exceeded

INFRA-8714 was auto-filed by fleet-doctor's `p0-budget` health check
(`src/gap_filer.rs` dedup tag `health-check:p0-budget`) asking to "review
and demote lower-priority P0s" because the open P0 count had exceeded the
budget of 5 (`scripts/coord/fleet-doctor-strict.sh` `check_p0_budget`,
CLAUDE.md "P0 budget = 5 max").

Verified against current state (2026-10-28) via three independent reads of
`.chump/state.db`:

```
$ chump gap audit-priorities --json | jq '.p0_count, .p0_gaps'
0
[]

$ bash scripts/coord/fleet-doctor-strict.sh --verbose | grep p0-budget
  ✓ PASS  p0-budget      0 open P0 gaps (threshold: <=5)

$ chump gap rebalance
Gap rebalance: 818 open gaps  (18 pickable P0/P1 xs/s/m)  P0=0/5
```

There are zero open P0 gaps right now, so there is nothing to demote. The
condition that triggered this gap has since cleared (other P0s were shipped
or demoted in the interim) — the `health-check:p0-budget`-tagged gap has no
auto-close path when the underlying check starts passing again, so it sat
open past the point where its premise became stale.

No code change needed. Closing as not-a-bug per the reality-check doctrine
(`AGENTS.md` → Reality-check before alarm-class beliefs, CREDIBLE-090) rather
than manufacturing demotion work against a budget that isn't actually over.
