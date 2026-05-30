# PR Ready-to-Ship — INFRA-2309

**Operator question:** "How do we know something has 0 failures and is still in CI? How do we just ship stuff that passes QA?"

**Answer:** `mergeStateStatus=CLEAN` is GitHub's signal that a PR has passed all required checks, has no merge conflicts, and is queued for auto-merge. INFRA-2309 surfaces those PRs on demand and keeps auto-merge armed even when force-pushes/rebases clear it.

---

## Quick start

```bash
# See all PRs that have passed QA right now
bash scripts/coord/chump-pr-ready-to-ship.sh

# Get raw JSON
bash scripts/coord/chump-pr-ready-to-ship.sh --json

# Arm auto-merge on every CLEAN PR immediately (one-shot)
bash scripts/coord/chump-pr-ready-to-ship.sh --arm

# Install the daemon so CLEAN PRs auto-ship continuously
bash scripts/setup/install-auto-merge-rearm-daemon.sh
```

---

## What "CLEAN" means

GitHub's `mergeStateStatus` field:

| Status | Meaning |
|---|---|
| `CLEAN` | All required checks pass, no conflicts, branch is up-to-date |
| `BEHIND` | Branch needs rebase before merge |
| `BLOCKED` | A required check failed or review is pending |
| `DIRTY` | Merge conflict exists |
| `UNKNOWN` | GitHub hasn't computed mergeability yet |

A PR is **ready to ship** when `mergeStateStatus=CLEAN` AND `autoMergeRequest` is non-null (auto-merge is armed).

The problem INFRA-2309 solves: force-pushes and rebases clear `autoMergeRequest` even when the PR stays CLEAN. The PR sits ready but never ships.

---

## The daemon

`scripts/coord/auto-merge-rearm-daemon.sh` runs every 60 seconds (via launchd) and:

1. Fetches all open PRs (`gh pr list --json mergeStateStatus,autoMergeRequest`)
2. Finds PRs where `mergeStateStatus=CLEAN` AND `autoMergeRequest=null`
3. Checks the title prefix against `scripts/coord/lib/fix-class-allowlist.txt`
4. If allowlisted: calls `gh pr merge --auto --squash` to re-arm
5. Emits an ambient event for each action

### Fix-class allowlist (safety brake)

By default only these PR title prefixes are auto-armed:

```
fix(   docs(   chore(   hotfix(   ci(
test(  revert( build(   style(    refactor(   perf(
```

`feat(` and other classes require operator review OR `CHUMP_AUTO_MERGE_REARM_OPEN=1`.

Edit `scripts/coord/lib/fix-class-allowlist.txt` to add/remove prefixes.

---

## Env knobs

| Variable | Default | Effect |
|---|---|---|
| `CHUMP_AUTO_MERGE_REARM_INTERVAL_S` | `60` | Seconds between daemon ticks |
| `CHUMP_AUTO_MERGE_REARM_DRY_RUN` | unset | Log only, no `gh pr merge` calls |
| `CHUMP_AUTO_MERGE_REARM_OPEN` | unset | Skip fix-class allowlist (arm everything CLEAN) |

---

## Ambient events

| Kind | When |
|---|---|
| `auto_merge_rearmed` | Auto-merge successfully armed on a CLEAN PR |
| `auto_merge_rearm_skipped` | CLEAN PR skipped — title not in allowlist |
| `auto_merge_rearm_failed` | `gh pr merge` returned non-zero |

Monitor: `grep '"kind":"auto_merge_rearm' .chump-locks/ambient.jsonl`

---

## Install / uninstall

```bash
# Install (runs every 60s via launchd)
bash scripts/setup/install-auto-merge-rearm-daemon.sh

# Dry-run mode install
CHUMP_AUTO_MERGE_REARM_DRY_RUN=1 bash scripts/setup/install-auto-merge-rearm-daemon.sh

# Open mode install (no fix-class filter)
CHUMP_AUTO_MERGE_REARM_OPEN=1 bash scripts/setup/install-auto-merge-rearm-daemon.sh

# Uninstall
launchctl unload ~/Library/LaunchAgents/dev.chump.auto-merge-rearm.plist

# Check it's running
launchctl list | grep auto-merge-rearm

# Logs
tail -f /tmp/chump-auto-merge-rearm.err.log
```

---

## Relation to existing tools

| Tool | Role |
|---|---|
| `scripts/coord/auto-merge-armer.sh` | Arms auto-merge at PR creation time (INFRA-1113) |
| `scripts/coord/auto-merge-rearm-daemon.sh` | Re-arms after force-push/rebase clears it (INFRA-2309) |
| `scripts/ops/auto-arm-sweeper.sh` | Periodic sweep for PRs that missed initial arm (INFRA-374) |
| `scripts/coord/chump-pr-ready-to-ship.sh` | On-demand CLEAN PR listing (INFRA-2309) |

The rearm daemon is the missing link: it closes the gap where a PR goes CLEAN after a rebase but auto-merge stays disarmed.
