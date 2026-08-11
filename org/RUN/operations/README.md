---
department: RUN/operations
status: thin
keystone: self-heal daemon + the VOA self-fix loop
driven_by: VOA-006, VOA-007, RESILIENT-257
mines: this session's daemons (pr-lander, triage, back-pressure, heartbeat, ci-flake-rerun) + the VOA loop
last_verified: 2026-08-11
---
# Operations / self-heal — keep the factory alive + honest

**Status: thin.** The factory catches and fixes its own sloppiness. Thin: daemons run on helsinki, but the VOA self-fix loop is broken until gap-import is resilient.

**Mine before build:** this session's daemons (pr-lander, triage, back-pressure, heartbeat, ci-flake-rerun) + the VOA loop

**To activate (thin → online):** work VOA-006, VOA-007, RESILIENT-257 → wire as driven-work chairs (typed artifact + gate), prove on customer 0, then productize.

**Chairs:** _(stub — flesh when staffed; see `../publication/roles/publisher.md` for the pattern)_
