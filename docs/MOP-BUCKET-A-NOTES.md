# MOP-BUCKET-A — closed not-a-bug

MOP-BUCKET-A ("Child A", RESILIENT, P2/s) is not real work. It is the fixture row inserted by
the outcome-no-movement tests in `src/fleet_health.rs` (the `MOP-BUCKET` outcome with a
`Child A` gap), which leaked into the real state.db. It has no description or acceptance criteria.

## Disposition

Closed as test-fixture pollution (race-* class, see `chump gap audit-priorities`). No code change.
The real MOP-BUCKET children are CREDIBLE-209 and EFFECTIVE-374.
