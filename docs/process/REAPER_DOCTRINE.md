# Reaper Doctrine — Rebase Before Reap

> Canonical policy for how the Chump fleet handles stale PRs.
> Gap: INFRA-2295. Last updated: 2026-05-30.

## The problem

The stale-pr-reaper (`scripts/ops/stale-pr-reaper.sh`) closes PRs whose gap
work is already on `main`. That is the right call for true duplicates.

It is the wrong call for PRs that are merely *behind* `main` — PRs with real,
unreplicated work that simply drifted while trunk was active. On 2026-05-30,
28 such PRs were destroyed in one reaper cycle during a 15:46Z trunk-RED storm.
INFRA-1809 and INFRA-1119 were killed on 2026-05-24 the same way.

The root cause: the reaper's BLOCKED/BEHIND filter is correct in intent but
blunt in practice. A PR can be BLOCKED because it needs a rebase, not because
it is duplicate work.

## The doctrine

**Rebase before reap.**

A PR that is stale (auto-merge armed, `updatedAt` older than
`CHUMP_REBASE_BOT_STALE_MINS`, default 120 min) should receive a rebase
attempt before any destructive action is taken. Only after repeated rebase
failures — the 3-strike threshold — should the operator be paged. The operator
alone decides whether to close the PR.

### Priority order for stale PRs

1. **GH-side rebase** (`gh pr update-branch <N>`) — zero local disk cost; let
   GitHub merge `main` into the PR branch. Succeeds for the vast majority of
   non-conflicting PRs.
2. **Local worktree rebase** — if `gh pr update-branch` returns non-zero (may
   be a false positive per INFRA-1958), clone the branch into a fresh `/tmp`
   worktree, run `git rebase origin/main`, and push `--force-with-lease`. This
   resolves INFRA-1958-class false conflicts.
3. **Strike counter** — if both methods fail, increment a per-PR strike counter
   at `.chump-locks/rebase-bot-strikes/<PR>.json`. The file records `strikes`,
   `pr`, `branch`, and `last_attempt_ts`.
4. **3-strike escalation** — after `CHUMP_REBASE_BOT_STRIKE_LIMIT` (default 3)
   failed rebase attempts, emit `kind=stale_pr_unrebaseable` to `ambient.jsonl`
   and send a WARN broadcast. **Never close the PR automatically.** The operator
   inspects the conflict, resolves it, or closes deliberately.

### Guards

- **Trunk-RED hold** — if `trunk-red-detector-state.json` has a
  `last_failed_sha`, the entire rebase-bot cycle is skipped. Rebasing branches
  onto a broken `main` wastes CI capacity. Emits
  `stale_pr_rebase_bot_holding_for_trunk_red`.
- **Hysteresis** — a PR is not re-attempted within
  `CHUMP_REBASE_BOT_HYSTERESIS_MINS` (default 30 min) of the last attempt.
  Prevents thrashing during transient GitHub API hiccups.

## Actors and their lanes

| Script | Lane | Destroys PRs? |
|---|---|---|
| `scripts/coord/stale-pr-rebase-bot.sh` | INFRA-2295 (SCALE-C) | Never |
| `scripts/coord/pr-auto-rebase.sh` | INFRA-1777 (cadence: 3–5 min) | Never |
| `scripts/ops/stale-pr-reaper.sh` | Hourly cron | Yes — only when ALL gaps on main + file parity OK |

The rebase bot and `pr-auto-rebase.sh` are **complementary, not competing**.
`pr-auto-rebase.sh` catches freshly-BEHIND PRs every few minutes with a
per-hour cooldown. The rebase bot adds the 3-strike doctrine and trunk-RED
guard on a 15-min cadence with 2-hour staleness threshold — targeting PRs that
have slipped past the fast daemon's cooldown window.

The reaper's INFRA-1410 auto-respawn path also attempts a rebase before
closing, but only after the PR has been BLOCKED for `CHUMP_PR_STUCK_SLO_HRS`
(default 2h) with no activity. The rebase bot's lane is upstream of that —
catch stale PRs earlier so fewer reach the respawn path.

## Operator response to `stale_pr_unrebaseable`

When you see `kind=stale_pr_unrebaseable` in `ambient.jsonl`:

1. Inspect the strike file: `cat .chump-locks/rebase-bot-strikes/<PR>.json`
2. View the conflict: `gh pr view <N>` — look at `mergeStateStatus`
3. Options:
   - **Resolve locally**: `git fetch origin && git checkout <branch> && git rebase origin/main` — fix conflicts — `git push --force-with-lease`
   - **Close deliberately**: `gh pr close <N> --comment "closing: unresolvable conflict after 3 rebase attempts"`
   - **Exempt from rebase bot**: add label `rebase-bot-exempt` (future enhancement — `gh pr edit <N> --add-label rebase-bot-exempt`)

After manual resolution, clear the strike file so the bot treats the PR as fresh:

```bash
rm .chump-locks/rebase-bot-strikes/<PR>.json
```

## Ambient event reference

| Kind | When |
|---|---|
| `stale_pr_auto_rebased` | Rebase succeeded (GH-side or local fallback) |
| `stale_pr_rebase_failed` | One attempt failed; strike incremented |
| `stale_pr_unrebaseable` | 3-strike limit reached; operator must decide |
| `stale_pr_rebase_bot_holding_for_trunk_red` | Trunk RED; cycle skipped |

## Configuration knobs

| Env var | Default | Effect |
|---|---|---|
| `CHUMP_REBASE_BOT_STALE_MINS` | `120` | Age threshold for "stale" |
| `CHUMP_REBASE_BOT_HYSTERESIS_MINS` | `30` | Min gap between re-attempts per PR |
| `CHUMP_REBASE_BOT_STRIKE_LIMIT` | `3` | Strikes before escalation |
| `CHUMP_REBASE_BOT_NO_FALLBACK` | `0` | Skip local-rebase fallback; trust gh API |

Launchd cadence: 900s (15 min). Install via
`scripts/setup/install-stale-pr-rebase-bot.sh`.
