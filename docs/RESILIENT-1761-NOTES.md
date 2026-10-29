# RESILIENT-1761 — closed not-a-bug: empty test-fixture gap, no real work item

RESILIENT-1761 has an empty title, empty description, empty acceptance
criteria, and empty notes in `.chump/state.db`:

```
$ sqlite3 .chump/state.db "SELECT id,title,description,acceptance_criteria,notes FROM gaps WHERE id='RESILIENT-1761';"
RESILIENT-1761||||
```

Scanning the surrounding ID range (`RESILIENT-1740`..`RESILIENT-1774`) shows
this is part of a recurring test-pollution pattern: titles like
`RESILIENT-1494 canonical store test`, `decomposed parent for close test`,
`integration test decomposed parent`, `child 1 (RESILIENT-XXXX slice)`, and
several other completely empty-titled rows (`RESILIENT-1764`,
`RESILIENT-1774`) — all created within seconds of each other
(`created_at` timestamps `1793221893`..`1793239932`), consistent with a test
suite exercising the gap-store / decompose code paths against the
production `state.db` instead of an isolated fixture DB.

`CREDIBLE-152` ("reserve guard — CI fixture titles must never enter the
canonical state.db") already closed one instance of this class (118 fixture
gaps + hijacked INFRA-001/002), but the guard evidently doesn't cover this
pattern (decompose-test and canonical-store-test fixtures, or blank
titles) — `INFRA-8198 dispatch-child-lifetime fixture gap` rows are a live
example of the same leak continuing post-CREDIBLE-152.

There is no feature or bug for RESILIENT-1761 to implement — it is leaked
test scaffolding, not a work item. Closing as not-a-bug per the
reality-check doctrine (`AGENTS.md` → Reality-check before alarm-class
beliefs, CREDIBLE-090) rather than inventing fictional work against an
empty gap.

Filed a follow-up to track the root-cause leak: see the INFRA gap opened
alongside this close (root-cause: test suites writing decompose/canonical-
store fixture gaps into the production `.chump/state.db` instead of an
isolated DB).
