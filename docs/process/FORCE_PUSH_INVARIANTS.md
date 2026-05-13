---
doc_tag: process
last_audited: 2026-05-13
gap: INFRA-958
audience: fleet maintainers, coord-script reviewers
companion_docs:
  - docs/process/CLAUDE_GOTCHAS.md
  - scripts/git-hooks/pre-push
---

# Force-push invariants (INFRA-958)

Five automation paths in `scripts/coord/` issue `git push --force-with-lease`. Each has a concurrency invariant that, if violated, can clobber an in-flight sibling's work. This page is the **single source of truth** for who force-pushes what, what lock protects each, and the failure mode if the invariant breaks.

> All five use `--force-with-lease` (never bare `--force`). The lease check protects against the ref-tip moving since fetch, but it does NOT serialize concurrent rebases of the same PR — see Invariant **C** below.

## Quick table

| Script | Line | What it pushes | Concurrency invariant | Lock |
|---|---|---|---|---|
| `bot-merge.sh` | 1454 | Final merged branch → `origin/<branch>` | One bot-merge at a time + per-file lock on hot files | `flock` on `bot-merge.lock` FD 200 + `hot-file-lock.sh` per file listed in `hot-files.yaml` |
| `queue-driver.sh` | 159, 206 | Rebased-onto-main HEAD → `origin/<branch>` | One queue-driver per host + skip-if-PR-younger-than-10min | Host-singleton (cron `lockfile`); per-PR cooldown |
| `pr-watch.sh` | 189, 226, 236 | Rebase fixups → `origin/<branch>` | Per-PR advisory cooldown (30 min) | None — relies on rare-event timing |
| `pr-rescue.sh` | 205 | Rebased HEAD after CI-flake reruns | Once per stuck-PR detection cycle (2h cron) | None — relies on cron cadence |
| `rebase-stacked-prs.sh` | 110 | Stacked-PR rebase chain | Caller-serialized (only invoked from bot-merge.sh) | Inherits bot-merge's flock |

## Invariants

### A. Bot-merge global serial lock (INFRA-860)

`bot-merge.sh` acquires an exclusive `flock` on `bot-merge.lock` (FD 200) with a 60s timeout. Held until the script process exits. Only one bot-merge runs per host at a time.

**Why:** `git push --force-with-lease` on the merged branch races with `gh pr merge` (which fetches the ref tip at the moment the API call runs); two bot-merges of different PRs landing simultaneously can interleave the lease ↔ merge sequence and one of them silently no-ops.

**Failure mode if violated:** Lost merge — the second PR's push gets accepted but `gh pr merge` saw the PRE-push tip, so the merge happens against the old SHA and the new commit is left dangling on origin.

### B. Bot-merge hot-file per-file lock (META-055 / INFRA-953)

In addition to **A**, `bot-merge.sh` consults `scripts/coord/hot-files.yaml` and acquires a per-file `flock` for every file in its diff that's on the `serialize:` list. Held for the duration of the bot-merge.

**Why:** Files like `docs/observability/EVENT_REGISTRY.yaml`, `.github/workflows/ci.yml`, and `scripts/ci/env-vars-internal.txt` accept additive contributions from many PRs and produce union-mergeable conflicts. The hot-file lock serializes the rebase + push for ANY PR touching the same hot file — across PRs that are otherwise unrelated.

**Failure mode if violated:** `bot_merge_hot_file` ambient event; ~71.5% of token waste in the 7-day META-055 audit window came from this class.

### C. Queue-driver per-PR cooldown (INFRA-727)

`queue-driver.sh` skips PRs younger than 10 min (avoids racing a still-running fleet-worker that just pushed) AND respects a 30-min per-PR cooldown after its own force-push.

**Why:** Without the cooldown, queue-driver can race a fleet-worker mid-edit: the worker's local branch is at SHA A, queue-driver rebases A→B and force-pushes B. The worker's next `git push` rejects (rightly), but the worker has unpushed work that's now invisible until they manually rebase.

**Failure mode if violated:** Worker dropped commits — silent because force-with-lease succeeded against the pre-cooldown ref. Mitigated by the fleet's worktree-isolated lease model (each worker writes to a per-gap `/tmp/chump-<gap>` checkout), but recovery is manual.

### D. PR-watch advisory cooldown

`pr-watch.sh` runs from a launchd cron (`com.chump.pr-watch.plist`, every 5 min). Uses an in-memory dedup of "PRs I touched this run" to avoid double-pushing within a single invocation. **No cross-invocation lock.**

**Why-not stricter:** pr-watch's force-pushes are rebase-fixups (clean rebase of an existing PR onto the latest main); the diff content doesn't change, only the parent SHA. Worst-case race: two cron invocations both force-push the same rebase — same final tree, last-writer-wins, no work lost.

**Acceptable failure mode:** Wasted CI cycle on the loser's force-push event (its CI cancels when the second push lands).

### E. PR-rescue cadence

`pr-rescue.sh` runs every 2h (cron). Single-host. Each invocation processes the list of stuck PRs once.

**Why:** Cadence is wide enough that two invocations overlapping is rare. If it does happen, fall back to **D**-class semantics.

## Force-with-lease guard (INFRA-345)

`scripts/git-hooks/pre-push` enforces an additional client-side check on every developer force-push:

1. Fetch latest origin.
2. Compare local `refs/remotes/origin/<branch>` to the ref tip from fetch.
3. If diverged within 30s of pre-push, refuse the push with a recovery hint.

This catches the case where a queue-driver or pr-watch rebased the branch milliseconds before the developer's `git push --force-with-lease` — without this guard, `--force-with-lease` alone wouldn't catch it because the developer's local origin ref might still be stale.

**Bypass:** `CHUMP_FORCE_LEASE_RACE_BYPASS=1 git push` — used only when the developer has confirmed via `git log origin/<branch>` that the divergence is their own prior push.

## When you write a new force-push site

Required checklist before merging code that adds `git push --force-with-lease`:

- [ ] What concurrency class above does this fit into?  (A/B/C/D/E or "new class")
- [ ] If "new class": is there a written invariant? Add it here.
- [ ] What's the failure mode if the invariant breaks?  (Lost work? Wasted CI? Silent no-op?)
- [ ] Does the failure mode get noticed?  (Ambient event? CI signal? Operator-visible?)
- [ ] Is there a recovery path?  (Manual rebase? Automated reaper?)

## Audit

Run `grep -rn 'force-with-lease\|push.*--force' scripts/ .github/workflows/ | grep -v ab-harness | grep -v test-` to find any new force-push site not listed in the table above. CI gate `scripts/ci/test-force-push-invariants.sh` (TODO: file as follow-up) should fail on any unlisted callsite.
