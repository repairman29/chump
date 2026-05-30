# Native Merge Queue Migration Spec

**Gap:** META-198  
**Status:** Design only — no implementation in this document  
**Date:** 2026-05-30  
**Author:** Chump fleet / operator review required before Phase 1

---

## 1. Current State

### What bot-merge.sh does

`scripts/coord/bot-merge.sh` (3292 LOC) is the fleet's sole merge engine. Every
agent branch ships by invoking it. The script performs:

1. **Preflight** — gap status checks, staleness guard (>50 commits behind: abort),
   GraphQL exhaustion guard, off-rails lease verification.
2. **Auto-derive gap ID** from branch name if `--gap` not provided.
3. **Rebase** — `git pull --rebase origin main` with custom merge drivers
   (`.gitattributes` union drivers for state.db, ci.yml, pre-commit, gap YAML).
4. **Local CI** — `cargo fmt`, optionally `cargo clippy`, optionally `cargo test`
   (flags: `--skip-tests`, `--fast`).
5. **Push** — `git push --force-with-lease origin <branch>`.
6. **PR open/update** — `gh pr create` or no-op if PR already exists.
7. **Auto-merge arming** — `gh pr merge --auto --squash` when `--auto-merge` is
   passed.
8. **Hot-file warning** — emits `bot_merge_hot_file` to `ambient.jsonl` when diff
   touches shared append-only files.
9. **Parallelism classification** — labels PR `pr:serializing` or `pr:parallel-safe`
   based on `SERIALIZING_HOT_FILES`.
10. **Post-arm sibling sweep** — closes other open PRs citing the same gap when
    `--speculative`.

**Exit codes are named** (RESILIENT-010/011): 10=preflight fail, 11=rebase fail,
12=fmt fail, 13=clippy fail, 14=test fail, 15=push fail, 16=PR fail.

The script has ~15 satellite files: `bot-merge-run-timed.py`, `bot-merge-circuit-breaker.sh`,
`bot-merge-recover.sh`, `bot-merge-watchdog.sh`, and supporting `lib/` helpers.

A Rust port (`chump-ship`) is in progress (INFRA-2001, `CHUMP_SHIP_RUST=1` feature
flag). The `--mode manual` path routes to Rust already; `--mode bot-merge` still
routes to bash (Phase 1 stub).

### Supporting daemons

| Script | Role | LOC |
|---|---|---|
| `scripts/coord/queue-driver.sh` | 5-min cron: rebases the oldest BEHIND PR with auto-merge armed; cascade-rebases all PRs when hot files change on main | 401 |
| `scripts/ops/stale-pr-reaper.sh` | Hourly: closes PRs whose gap is already `done` on main AND branch is >15 commits behind | 616 |
| `scripts/coord/stale-pr-rebase-bot.sh` | Finds stale auto-merge-armed PRs and attempts rebase before reaper closes them; 3-strike limit then `stale_pr_unrebaseable` | 361 |
| `scripts/coord/cascade-rebase-detector.sh` | Detects hot-file commits on main and triggers cascade rebase (overlaps with queue-driver.sh `cascade_rebase_if_hot`) | ~100 |
| `scripts/coord/auto-merge-armer.sh` | Arms auto-merge on PRs that pass a green-check scan | ~120 |

Combined surface: ~5000 LOC of shell managing the merge queue by hand.

### Required checks

Branch protection requires four aggregator jobs:

- `clippy-required` — cargo clippy rollup
- `cargo-test-required` — nextest rollup
- `fast-checks-required` — fmt + light script checks rollup
- `audit-required` — gap-audit + misc checks rollup

All four already include `merge_group` in their trigger conditionals (added
2026-05 per INFRA-2095). The workflows fire on `pull_request | push | merge_group`.
No rewire is needed for the event trigger; the gap is in check naming continuity
(see Section 5).

### Pain points that motivate this migration

- **30+ PRs stuck simultaneously** (incident 2026-05-30): bot-merge.sh processes
  PRs serially; under fleet load the queue backs up faster than it drains.
- **Reaper-storm** (RESILIENT-050, 2026-05-30T15:45Z): stale-pr-reaper closed 28
  in-flight PRs in 60 seconds because trunk was RED and PRs were BLOCKED >2h30m.
  Native merge queue has a configurable group timeout and fail-fast policy that
  prevents this pattern.
- **Rebase loop amplification**: queue-driver.sh rebases BEHIND PRs, each rebase
  invalidates other PRs, which then need rebase — O(n²) round-trips under load.
- **Admin-merge proliferation** (INFRA-2274): ~105 PRs landed without consensus
  verification because the manual queue couldn't keep up. Native queue enforces
  checks at batch-merge time without operator bypass.

---

## 2. Target State

GitHub's native merge queue (`merge_group` event) batches PRs into groups,
runs CI against the merged-together commit, and merges the batch atomically if
all checks pass.

### Configuration parameters (to be set per operator decision before Phase 1)

| Parameter | Proposed value | Rationale |
|---|---|---|
| Merge method | squash | Matches current `--squash` default in bot-merge.sh; keeps main history linear |
| Min group size | 1 | Allow single-PR groups; don't artificially delay small PRs |
| Max group size | 5 | Limits blast radius of a failing group; tunable up after stability |
| Group timeout | 30 min | Matches `CHUMP_BOT_MERGE_STAGE_BUDGET_S` (300s per stage + overhead) |
| Fail-fast | true initially | Fail on first check failure; revisit once queue is stable |
| Check-passing status | Required | Same 4 checks; fire on `merge_group` event |

### What the fleet does differently

- Agents push a branch and open a PR as today. They call `gh pr merge --auto`
  (or the equivalent) to enqueue the PR.
- GitHub handles batching, rebase-onto-main, CI run, and merge — no Chump
  script manages this.
- Agents no longer need to poll for BEHIND state or trigger rebases.
- `kind=merge_queue_entry_added` / `kind=merge_queue_entry_merged` / `kind=merge_queue_entry_failed`
  ambient events replace the current bot-merge phase events for observability.

---

## 3. Migration Phases

### Phase 1 — Enable merge queue on docs-only PRs (operator gated)

**Scope:** PRs labeled `docs-only` (branch protection ruleset targets this label
or branch pattern, not all PRs).

**Actions:**
- Enable merge queue on the repo (GitHub Settings > Rules > Merge queue).
- Configure as above but with `max_group_size = 2` (low risk, learn behavior).
- Add a `queue-docs-only` GitHub Actions workflow that adds the `docs-only` PR
  to the merge queue when labeled (replaces `gh pr merge --auto` for that label).
- Monitor: watch `merge_group` check runs, queue depth, merge latency.

**Success criteria:**
- 5 docs-only PRs merged via queue without manual intervention.
- No required-check name breakage (check names appear identically in branch
  protection and in merge-group CI run summaries).
- Queue timeout not triggered once.

**What does NOT change:** bot-merge.sh still used for all other PRs.

### Phase 2 — Enable for all PRs except explicit opt-out (operator gated)

**Scope:** All open PRs, except those labeled `no-merge-queue`.

**Actions:**
- Expand merge queue ruleset to all branches (`chump/**`).
- bot-merge.sh's `--auto-merge` flag replaces its `gh pr merge --auto --squash`
  call with `gh pr merge --merge-queue` (or equivalent when gh CLI supports it
  natively; fallback: REST API call to add PR to queue).
- stale-pr-rebase-bot.sh goes into advisory mode: still emits
  `stale_pr_unrebaseable` events, but stops attempting local rebases (the queue
  rebases batches).
- queue-driver.sh's `cascade_rebase_if_hot` function is disabled
  (`CHUMP_QUEUE_DRIVER_CASCADE=0`) — the merge queue handles this.
- Monitor: watch for queue depth growth, group timeout events, PR stuck patterns.

**Success criteria:**
- Queue drains 10+ PRs per hour sustained (current manual rate: ~3-5/hr).
- `pr_stuck` ambient events drop by 50% vs Phase 1 baseline.
- No `stale_pr_unrebaseable` events caused by the queue (those should only come
  from genuine merge conflicts).

### Phase 3 — Deprecate bot-merge.sh auto-merge arming (operator gated)

**Scope:** The auto-merge arming path in bot-merge.sh.

**Actions:**
- Remove or no-op the `gh pr merge --auto --squash` call in bot-merge.sh (the
  queue entry is now added at PR-open time by a lightweight hook or by the agent
  calling `chump queue-add <PR>`).
- bot-merge.sh retains: push, PR create/update, hot-file warnings, preflight,
  local CI (fmt/clippy/test). Its job narrows to "push the branch and open the
  PR"; the queue handles the rest.
- stale-pr-reaper.sh continues but its BEHIND threshold becomes irrelevant —
  the queue keeps PRs current. Keep for ghost-PR cleanup only.
- INFRA-2274 consensus gate moves from bot-merge.sh pre-merge position to a
  merge-group status check. A new required check `consensus-required` fires on
  `merge_group` events and calls `chump consensus-tally` for the batch. This is
  the correct architectural home: consensus runs against the about-to-merge
  commit, not against an intermediate branch.

**Success criteria:**
- bot-merge.sh invocations no longer arm auto-merge; all auto-merge is queue-driven.
- INFRA-2274 consensus gate fires on `merge_group` at least 10 times without
  false-positive blocks.
- No regression in merge rate vs Phase 2 baseline.

### Phase 4 — Delete bot-merge.sh and dependent scripts (operator gated)

**Scope:** Full removal of the hand-rolled queue layer.

**Actions:**
- Delete `scripts/coord/bot-merge.sh` and its satellites (see Section 4).
- `chump-ship` (Rust, INFRA-2001) becomes the sole ship path. It handles: push,
  PR create, queue-add. No local rebase loop; no parallelism classifier; no
  hot-file warning (the queue handles sequencing).
- Delete queue-driver.sh, stale-pr-rebase-bot.sh, cascade-rebase-detector.sh.
- stale-pr-reaper.sh is kept in reduced form (ghost-PR cleanup).
- File a follow-up gap to migrate chump-ship's `BotMergePath` stub to use the
  GitHub merge queue API directly.

**Success criteria (definition of done for META-198):**
- Zero references to bot-merge.sh in agent-facing docs and CI.
- All 4 required checks confirmed firing on `merge_group` in prod.
- Merge rate at Phase 4 equals or exceeds Phase 2 peak.

---

## 4. Script Disposition Table

| Script | LOC | Disposition | When | Notes |
|---|---|---|---|---|
| `scripts/coord/bot-merge.sh` | 3292 | DELETE | Phase 4 | Replaced by `chump-ship` + queue API |
| `scripts/coord/bot-merge-run-timed.py` | ~80 | DELETE | Phase 4 | Helper for bot-merge.sh stage timeouts |
| `scripts/coord/bot-merge-circuit-breaker.sh` | ~60 | DELETE | Phase 4 | Phase watchdog; queue replaces the need |
| `scripts/coord/bot-merge-recover.sh` | ~80 | DELETE | Phase 4 | Crash recovery for bot-merge.sh |
| `scripts/coord/bot-merge-watchdog.sh` | ~50 | DELETE | Phase 4 | Health file watcher for bot-merge.sh |
| `scripts/coord/queue-driver.sh` | 401 | MODIFY then DELETE | Phase 2 → Phase 4 | Phase 2: disable cascade_rebase_if_hot; Phase 3: disable BEHIND poll; Phase 4: delete |
| `scripts/coord/stale-pr-rebase-bot.sh` | 361 | MODIFY then DELETE | Phase 2 → Phase 4 | Phase 2: advisory-only (no rebase actions); Phase 4: delete |
| `scripts/ops/stale-pr-reaper.sh` | 616 | KEEP (reduced scope) | Phase 3 | Retain for ghost-PR cleanup (gaps already done on main); disable BEHIND-threshold close logic |
| `scripts/coord/cascade-rebase-detector.sh` | ~100 | DELETE | Phase 3 | Queue handles cascade rebase |
| `scripts/coord/auto-merge-armer.sh` | ~120 | DELETE | Phase 3 | Queue entry replaces auto-merge arming |
| `scripts/coord/break-trunk-cascade.sh` | — | KEEP | — | Operator emergency tool; unrelated to queue flow |
| `INFRA-2274` consensus gate | — | REVISIT (Phase 3) | Phase 3 | Move from bot-merge.sh pre-merge hook to `merge_group` required check (`consensus-required`); architectural improvement |
| chump-integrator daemon (INFRA-2130) | Rust | REVISIT | Phase 3 | Integration-cycle approach (batch N gaps, build integration branch, run CI, ship) overlaps with native queue batching. Design question: does chump-integrator become a queue feeder (adds PRs to queue) rather than a queue replacer? Needs separate design doc. |
| `chump-ship` (INFRA-2001) | Rust | KEEP + EXTEND | Phase 4 | Gains `queue-add` subcommand; `BotMergePath` stub replaced with queue API call |

**Scorecard:** 8 delete, 2 modify-then-delete, 1 keep-reduced, 2 keep, 2 revisit.

---

## 5. Required-Checks Rewire

### Current state

All four required checks already include `merge_group` in their `if:` conditionals
(confirmed in `.github/workflows/ci.yml` line 465, 592, 1075, 1134, 1235, 1342):

```
if: github.event_name == 'pull_request' || github.event_name == 'push' || github.event_name == 'merge_group'
```

The `changes` job (paths filter) also fires on `merge_group` with all paths
considered changed, so CI is not accidentally skipped for merge-group runs.

### Gap: check name continuity

Branch protection refers to checks by **name string**, not by job ID. The current
aggregator job names (`clippy-required`, `cargo-test-required`, `fast-checks-required`,
`audit-required`) must remain identical after any workflow restructuring, or the
merge queue will block indefinitely waiting for checks that never appear.

**Rule:** Never rename a required aggregator job without simultaneously updating
the branch protection ruleset and verifying in a test PR before the ruleset
change takes effect.

### Gap: grace-window system interaction

`required-check-monitor.sh` (INFRA-1395) dispatches workflows with `grace=1` for
pre-grace PRs when a new required check is added. Under merge queue, a grace-window
check that fires neutral on PR events but required on `merge_group` events would
silently block the queue. Before adding any new required check during migration,
confirm the grace-window sentinel also fires neutral on `merge_group`.

The existing `required-check-grace-guard` job (CI line 578) handles this for PR
events. Extend its `if:` to also handle `merge_group` events before Phase 2.

### Proposed consensus check addition (Phase 3)

When the INFRA-2274 consensus gate moves to a `merge_group` required check:

1. Add job `consensus-required` to `ci.yml`, firing only on `merge_group`.
2. Job calls `chump consensus-tally <PR_list_from_merge_group>`.
3. Returns neutral on `pull_request` events (not required there; vote collection
   happens during PR lifetime, not at merge time).
4. Add to branch protection ruleset as required for `merge_group` only.
5. Grace window: 30 min standard via INFRA-1395 mechanism, extended for the
   `merge_group` path per gap above.

---

## 6. Risk and Rollback

### Risks during migration

| Risk | Likelihood | Mitigation |
|---|---|---|
| Required check name mismatch blocks queue | Medium | Validate check names appear in merge-group run before enabling queue on `chump/**` |
| Open PRs at Phase 2 cut-over are not in queue | High | After enabling queue, existing auto-merge-armed PRs need `gh pr merge --queue` re-arm; bot-merge.sh re-run or a one-shot migration script |
| In-flight bot-merge.sh processes when Phase 3 removes `--auto-merge` | Medium | bot-merge.sh still runs through Phase 3; only the arming call changes; no in-flight breakage |
| chump-integrator (INFRA-2130) conflicts with native queue batching | Medium | Keep both operational through Phase 3; design doc for INFRA-2130 interaction required before Phase 4 |
| Fail-fast=true causes entire group to fail on one PR's flaky test | Medium | Monitor flake rate in queue context; switch to `fail-fast=false` if flake-caused group failures exceed 10% |
| GraphQL exhaustion during queue drain | Low | Cache-first reads (INFRA-1081) and criticality tags (INFRA-1080) are already in place; queue API uses REST not GraphQL |

### Rollback procedure

Each phase is independently reversible:

- **Phase 1 rollback:** Disable merge queue in GitHub Settings. No script changes
  were made.
- **Phase 2 rollback:** Re-enable `cascade_rebase_if_hot` in queue-driver.sh
  (`CHUMP_QUEUE_DRIVER_CASCADE=1`). Set `stale-pr-rebase-bot.sh` back to active
  mode. Remove the `--merge-queue` flag from bot-merge.sh.
- **Phase 3 rollback:** Re-add the `gh pr merge --auto --squash` call to
  bot-merge.sh (it's in git history). Remove `consensus-required` from branch
  protection, then from ci.yml.
- **Phase 4 rollback:** Not reversible without restoring from git. Phase 4 must
  only proceed after 30-day stable operation at Phase 3.

### Required-check naming continuity

Before any phase that touches ci.yml or branch protection:

1. In a test branch, rename no aggregator jobs.
2. Confirm the merge-group run shows all 4 required check names.
3. Only then proceed.

If a name is accidentally changed, the queue silently blocks. Recovery: rename
the job back or update branch protection — queue unblocks on next CI run.

---

## 7. Cost-Benefit

### Estimated wall-clock saved per merge

Current serial path: each PR takes ~3-8 min in bot-merge.sh (rebase + fmt + push
+ PR create + arm). Under a 30-PR backlog this is 90-240 min serial.

Native queue: groups of 5 PRs run CI in parallel. Assuming 5-min CI per group,
a 30-PR backlog drains in 6 groups × 5 min = 30 min. **6-8x throughput
improvement at current CI speed.**

### Scripts deleted

8 scripts deleted outright, 2 modified then deleted. Estimated LOC removed:
~4,600 LOC of bash (bot-merge.sh + satellites + queue-driver.sh + stale-pr-rebase-bot.sh
+ cascade-rebase-detector.sh + auto-merge-armer.sh). stale-pr-reaper.sh shrinks
by ~200 LOC (BEHIND-threshold logic removed).

### Complexity reduction

- No more per-stage watchdogs, hang alerts, circuit breakers, or health files.
- No more cascade rebase storms from hot-file commits.
- No more DIRTY PR resolution scripts (queue rebases batches cleanly).
- Reaper-storm class of incidents (RESILIENT-050) becomes structurally impossible:
  the queue has a configurable timeout, not a behind-commits threshold.

### Complexity added

- GitHub merge queue is a managed service dependency; outages block all merging
  until manual `gh pr merge --admin` recovery.
- `merge_group` CI semantics differ from PR CI in subtle ways (different `github.sha`,
  different context variables). Any workflow that reads PR number from event context
  needs review.
- chump-integrator's integration-cycle approach requires a design decision (Section 4
  revisit item) before Phase 4.

---

## 8. Operator Approval Gates

Each phase requires explicit operator sign-off before proceeding. Sign-off is
recorded by emitting to `ambient.jsonl` and leaving a comment on the META-198
gap:

```bash
# Template for operator approval
printf '{"ts":"%s","kind":"merge_queue_phase_approved","phase":%d,"operator":"%s","note":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <N> "jeffadkins" "<rationale>" \
  >> .chump-locks/ambient.jsonl
```

| Gate | What operator must verify before proceeding |
|---|---|
| Before Phase 1 | GitHub merge queue is enabled on the repo in Settings; ruleset targets docs-only PRs only; 5 test PRs queued manually and merged successfully |
| Before Phase 2 | Phase 1 success criteria met (logged); `required-check-grace-guard` extended to `merge_group` events; one-shot migration script for existing auto-merge-armed PRs reviewed |
| Before Phase 3 | Phase 2 success criteria met; INFRA-2274 consensus gate design confirmed for `merge_group` context; chump-integrator interaction design decision recorded |
| Before Phase 4 | Phase 3 stable for 30 days; chump-ship `queue-add` subcommand shipped and tested; chump-integrator design decision resolved; no open `pr_stuck` cluster in last 7 days |

---

## 9. References

- [GitHub merge queue documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
- [GitHub merge_group event reference](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#merge_group)
- `scripts/coord/bot-merge.sh` — current merge engine (3292 LOC)
- `scripts/coord/queue-driver.sh` — BEHIND-PR rebase daemon (401 LOC)
- `scripts/ops/stale-pr-reaper.sh` — ghost-PR reaper (616 LOC)
- `scripts/coord/stale-pr-rebase-bot.sh` — pre-reap rebase safety net (361 LOC)
- `docs/process/REAPER_DOCTRINE.md` — reaper operating principles
- `docs/design/GITHUB_LIAISON.md` — existing GitHub API integration design
- INFRA-2001 — chump-ship Rust port (partially live under `CHUMP_SHIP_RUST=1`)
- INFRA-2130 — chump-integrator daemon (integration-cycle approach; revisit item)
- INFRA-2274 — consensus gate wiring (moves to `merge_group` check in Phase 3)
- RESILIENT-050 — reaper-storm incident 2026-05-30 (precipitating incident)
- META-131 — parent gap (fleet ship-pipeline modernization umbrella)
