# MISSION-123 — closed as duplicate of already-shipped work

**Finding:** all 4 acceptance criteria for MISSION-123 ("Update node capacity
planner to trigger shedding on limit breach") are already satisfied on `main`
by PR #5225 (commit `3528c5ade`, merged 2026-10-10T00:31Z — before this gap
was claimed), which added `shed_target()` and shed wiring to
`scripts/ops/node-capacity-plan.sh`:

1. **AC1** — `shed_target LOAD_PCT HARD_LIMIT_PCT WORKERS_UP` is a pure
   function that returns `"shed"` once `load_pct_per_core` strictly exceeds
   `CHUMP_PLAN_HARD_LIMIT_PCT` (default 200), and `"none"` otherwise.
2. **AC2** — when a shed is triggered, `plan()` stops the lowest-priority
   (highest-numbered) worker unit via `systemctl stop` and records the freed
   capacity in `plan.json`'s `shed` object (`action`/`target`).
3. **AC3** — the log line emitted on breach is exactly
   `auto-size shed triggered: load ...`.
4. **AC4** — `shed_target` never sheds the last worker (`workers_up <= 1` ⇒
   `"none"`), and normal-load capacity math (`compute_worker_budget`) is
   untouched — covered by the pre-existing unit cases.

Covered by `scripts/ci/test-node-capacity-plan.sh`. Verified green locally in
this session:

```
$ bash scripts/ci/test-node-capacity-plan.sh
...
node-capacity-plan formula: all cases pass
=== MISSION-123: planner shed-on-breach integration ===
ok   — AC3: log contains explicit 'auto-size shed triggered' (=2)
ok   — AC2: shed stopped the lowest-priority (highest-numbered) build chump-cj-worker3 (=chump-cj-worker3)
ok   — AC1: plan.json records the shed action (="action": "shed")
ok   — AC2: plan.json names the shed target (="target": "chump-cj-worker3")
ok   — AC4: normal load does not trigger a shed (="action": "none")
ok   — AC4: normal load issues no systemctl stop (=clean)
node-capacity-plan shed integration: all cases pass
```

No new code needed — this gap is closed as a duplicate rather than
re-implementing the same coverage a second time. Precedent: MISSION-122
(#5231), RESILIENT-1215/1216 (#5228/#5229) closed the same way for
already-shipped work.
