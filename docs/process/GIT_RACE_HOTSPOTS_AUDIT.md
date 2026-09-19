# Git race-condition hotspot audit — scripts/coord + scripts/dispatch (INFRA-7681)

INFRA-1966 slice. Scope: enumerate scripts in `scripts/coord/` and
`scripts/dispatch/` that perform git operations (`commit`, `push`, `pull`,
`checkout`, `merge`, `rebase`, `add`, `fetch`, `worktree`) **without** any
synchronization primitive (`flock`, a `.lock` file, or a lock directory), and
flag the specific functions/subshells where concurrent git access can race.

This is an audit only — no behavior change. Findings feed follow-up gaps
under INFRA-1966.

## Method

```bash
# Scripts that call a git-mutating subcommand:
grep -lE '\bgit (commit|push|pull|checkout|merge|rebase|add|fetch|worktree)\b' \
  scripts/coord/*.sh scripts/dispatch/*.sh

# Of those, scripts with NO lock/flock synchronization anywhere in the file:
grep -lE 'flock|\.lock\b|LOCKFILE|lockdir|mkdir.*lock' scripts/coord/*.sh scripts/dispatch/*.sh
# (subtract this set from the first)
```

56 scripts touch git. 39 already use `flock`/lockfile/lockdir synchronization
somewhere (e.g. `bot-merge.sh`, `queue-driver.sh`, `pr-auto-rebase.sh`,
`merge-serializer.sh`, `worker.sh` — these are out of scope for this audit).
**44 scripts perform git operations with no synchronization primitive at
all.** Full list: `scripts/coord/{archive-superseded-branch,armed-pr-rebaser,
board-tick,bot-merge-circuit-breaker,check-worktree-config,chump-ci-retrigger,
chump-rebase-and-push,chump-runner-migration-pipeline,
conflict-resolution-consumer,conflict-resolver-agent,demo-pr-worktree,
disk-pressure-reaper,dispatch-health-check,ensure-chump-repo,
fleet-doctor-strict,freshness-preamble,keep-mergeable-organ,keep-mergeable,
last-mile-rescuer,main-preflight-watchdog-daemon,main-worktree-drift-detector,
oracle-refresh,orphan-worktree-watchdog,pattern-fix-dispatcher,
post-push-integrity-watch,post-rebase-verify,pr-failure-auto-rescue,
pr-pulse-consumer,pr-rescue-false-close,pr-revert,pr-watch,
quartermaster-audit-loop,rebase-stacked-prs,stale-pr-rebase-bot,
target-dir-reaper,transient-retrigger,wedge-recover,worktree-prune}.sh`,
`scripts/dispatch/{board-ceo-briefing-beat,board-cycle-beat,control,
fleet-status,investigate-agent,pr-lander-beat}.sh`.

Most of these are read-only (`git fetch`, `git worktree list`) or single-shot
tools with no daemon loop — low risk. The list below narrows to the ones
that actually **mutate shared git state** (branches, the index, or
`.git/worktrees/` metadata) from a **recurring/concurrent context** —
these are the real race-condition hotspots.

## Hotspots (AC #2: functions / subshell blocks with real concurrency risk)

### 1. Shared-checkout mutation (no worktree isolation)

These run `git checkout -b` / `git add` / `git commit` / `git push`
**directly against whatever tree the script happens to run in**, with no
`git worktree add` isolation and no lock. If two invocations run
concurrently (e.g. two daemon ticks, or a daemon plus a manual run) against
the same checkout, they race on the index and `HEAD`.

- `scripts/coord/pattern-fix-dispatcher.sh:199-203` — `git checkout -b
  "$BRANCH"` → `git add -A` → `git commit` → `git push -u origin "$BRANCH"`
  runs in-place. Two concurrent pattern-fix dispatches (different patterns,
  same checkout) will stomp each other's `git checkout -b` / index state.
- `scripts/coord/pr-revert.sh:34-42` — `git fetch` → `git checkout -b
  "$REVERT_BRANCH" "origin/$BASE_BRANCH"` → `git revert` → `git push`, all
  in-place, no lock. Concurrent revert requests race on `HEAD`/index the
  same way.
- `scripts/coord/chump-runner-migration-pipeline.sh:141,148,188,190,231` —
  each stage does `git add .github/workflows/ci.yml` then `git push -u
  chump <branch> --no-verify` in-place. `--loop` mode (documented at the top
  of the file) polls every 60s; a second concurrent invocation (manual +
  loop, or two loops) would race on the same working tree.
- `scripts/coord/ensure-chump-repo.sh:33` — bare `git push "$@"` with no
  isolation; intended as a thin wrapper, so the race risk is inherited by
  whatever caller invokes it concurrently.

### 2. `git worktree add/remove` races on shared `.git/worktrees` metadata

`git worktree` mutates repo-wide metadata under `.git/worktrees/` that is
**not process-safe under concurrent add/remove/prune** without external
locking (a documented git limitation, not chump-specific). None of the
following take a lock before calling `git worktree`:

- `scripts/coord/armed-pr-rebaser.sh:58-68` — per-PR loop: `git worktree
  remove "$wt" --force` immediately followed by `git worktree add -B "$br"
  "$wt" "origin/$br"`. If two rebaser instances (or this + `keep-mergeable.sh`
  / `stale-pr-rebase-bot.sh` below) pick the same PR in the same tick, the
  `$wt` path collides mid-remove/add.
- `scripts/coord/keep-mergeable.sh:101-111` and
  `scripts/coord/keep-mergeable-organ.sh:243-252` — same
  remove-then-add-then-rebase-then-push pattern, same PR-derived worktree
  path convention, no lock. These two scripts look like they cover
  overlapping responsibility (rebase+re-arm on BEHIND/BLOCKED PRs) — running
  both against the same PR concurrently is a direct worktree-path collision.
- `scripts/coord/stale-pr-rebase-bot.sh:297-309` and
  `scripts/coord/wedge-recover.sh:130-162` — identical shape
  (`git worktree add` → `cd`-subshell `git rebase origin/main` → `git push
  --force-with-lease` → `git rebase --abort` on failure), no lock, PR-keyed
  worktree paths. Any pair of {armed-pr-rebaser, keep-mergeable,
  keep-mergeable-organ, stale-pr-rebase-bot, wedge-recover} racing the same
  PR number is a collision waiting to happen — five independent
  implementations of "rebase this PR's worktree" with no shared mutex.
- `scripts/coord/oracle-refresh.sh:194-203` — `git worktree add "$WORKTREE"
  -b "$BRANCH" origin/main` then, in a subshell, `git add` + `git commit` +
  `git push`. Branch name is timestamp-derived (`$STAMP`) so same-second
  concurrent runs could collide; no lock guards the worktree-add step itself
  against a concurrent prune (see next item).
- `scripts/coord/worktree-prune.sh:264,285` and
  `scripts/coord/target-dir-reaper.sh` / `scripts/coord/
  orphan-worktree-watchdog.sh` / `scripts/coord/
  main-preflight-watchdog-daemon.sh:182,191` — all periodically run
  `git worktree remove`/`add`/`prune` as daemons/cron ticks with no lock.
  Any of these firing while one of the rebase scripts in the item above is
  mid `worktree add`/`remove` on the same or an adjacent path is the
  textbook "prune removed the worktree the rebaser was still using" race.

### 3. In-place branch juggling with a temp branch (shared checkout)

- `scripts/coord/rebase-stacked-prs.sh:100-116` — explicitly comments "avoids
  polluting checked-out branch" but the mitigation is a **temp branch in the
  same checkout**, not a separate worktree: `cd "$REPO_ROOT"` (subshell) →
  `git checkout -B "$_tmp_branch" ...` → `git rebase` → `git push` → `git
  checkout - `. The subshell only protects the shell's `cwd`/exit status —
  `git checkout -B` inside it still mutates the **shared** working tree and
  index for the whole repo. A concurrent `git status`/commit/checkout
  anywhere else against `$REPO_ROOT` mid-loop will observe (or race) the
  temp branch checkout. The cleanup line 116 (`git -C "$REPO_ROOT" branch -D
  "$_tmp_branch"`) also runs unconditionally outside the subshell, so a
  second concurrent iteration reusing a colliding `$(date +%s)`-based temp
  branch name (same-second dispatch) can delete a branch the other iteration
  is still rebasing.

### 4. Fetch-then-decide without a freshness lock (lower severity, noted for completeness)

- `scripts/coord/board-tick.sh:16`,
  `scripts/dispatch/{board-ceo-briefing-beat,board-cycle-beat,pr-lander-beat}.sh`,
  `scripts/coord/quartermaster-audit-loop.sh:101,124,214` — all do a bare
  `git fetch origin main -q || true` on every tick with no lock. Read-only
  fetches don't corrupt state, but concurrent fetches from many
  simultaneously-ticking daemons are wasted network/API calls rather than a
  correctness race — noted here as a Zero-Waste follow-up, not a
  correctness hotspot.

## Summary table

| Script | Function/block | Git ops | Isolation | Risk |
|---|---|---|---|---|
| pattern-fix-dispatcher.sh | main body :199-203 | checkout -b, add, commit, push | none (in-place) | high |
| pr-revert.sh | main body :34-42 | fetch, checkout -b, revert, push | none (in-place) | high |
| chump-runner-migration-pipeline.sh | stage_1/stage_2/stage_3 :141-231 | add, push --no-verify | none (in-place), `--loop` mode | high |
| armed-pr-rebaser.sh | rebase loop :58-68 | worktree remove/add, rebase, push | worktree, but no lock; path collides with siblings below | high |
| keep-mergeable.sh | rebase loop :101-111 | worktree remove/add, rebase, push | same pattern, no lock | high |
| keep-mergeable-organ.sh | rebase loop :243-252 | worktree add, rebase, push | same pattern, no lock | high |
| stale-pr-rebase-bot.sh | rebase loop :297-309 | worktree add, rebase, push | same pattern, no lock | high |
| wedge-recover.sh | rebase loop :130-162 | worktree fetch/add, rebase, push | same pattern, no lock | high |
| oracle-refresh.sh | refresh :194-203 | worktree add, commit, push | worktree, no lock vs. pruners | medium |
| worktree-prune.sh / target-dir-reaper.sh / orphan-worktree-watchdog.sh / main-preflight-watchdog-daemon.sh | prune ticks | worktree remove/add/prune | none, daemon cadence | medium (collides with rows above) |
| rebase-stacked-prs.sh | rebase loop :100-116 | checkout -B (temp branch), rebase, push, branch -D | subshell only, not a real isolation boundary | high |
| board-tick.sh + dispatch/*-beat.sh + quartermaster-audit-loop.sh | tick fetch | fetch origin main | none | low (waste, not correctness) |

## Not in scope / already synchronized (for reference)

`bot-merge.sh`, `queue-driver.sh`, `pr-auto-rebase.sh`, `merge-serializer.sh`,
`local-merge-queue.sh`, `worker.sh`, `pr-rescue.sh`, `rescue-stale-pr.sh`,
`hot-file-lock.sh`, `chump-commit.sh`, and 29 others already gate their git
mutations behind `flock`/lockfile/lockdir — these were excluded from the
grep-diff above and are the pattern the hotspots in this doc should converge
toward.

## Suggested follow-up (not filed as part of this gap; file separately under INFRA-1966)

The five independent PR-rebase implementations in §2 (armed-pr-rebaser,
keep-mergeable, keep-mergeable-organ, stale-pr-rebase-bot, wedge-recover)
are the highest-value target: a single `flock`-guarded, PR-number-keyed
worktree-rebase primitive (consolidating the five) would close most of the
hotspots in this audit in one shot, and would let `worktree-prune`-class
daemons take the same lock before removing a worktree.
