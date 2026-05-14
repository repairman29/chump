# PR #1908 close audit: dedup gate vs. orphan closer vs. branch deletion

**Date:** 2026-05-14  
**Gap:** CREDIBLE-066  
**Incident:** PR #1908 (INFRA-1240) closed without merge at 17:31:17Z while PR #1921 shipped the same gap successfully.

## What happened — timeline

| Time (UTC) | Event |
|---|---|
| 17:30:07Z | Operator ran `chump claim INFRA-1240` (second claim attempt; worktree cleanup) |
| 17:31:11Z | `git branch -D chump/infra-1240-claim && chump claim INFRA-1240` — deleted local branch, re-claimed |
| 17:31:16Z | `gh api repos/:owner/:repo/git/refs/heads/chump/infra-1240-claim -X DELETE` fired |
| 17:31:17Z | GitHub auto-closed PR #1908 (head branch deleted → PR closed, `closed_by=null`) |
| (later)   | PR #1921 for INFRA-1240 shipped successfully and merged |

## Which mechanism closed #1908?

**Branch deletion by the operator (via `chump claim` cleanup path), NOT:**
- INFRA-1219 (pr-create dedup gate) — did not fire; #1908 was already closed by the time #1921 was created.
- INFRA-1139 (orphan-pr-closer) — no `orphan_pr_closed` event in ambient.jsonl for #1908 or INFRA-1240 near close time.

GitHub's behavior: when a PR's head branch is deleted via REST, GitHub closes the PR automatically with `state=closed`, `merged_at=null`, and `closed_by=null`. This makes the event indistinguishable from a manual operator close in the issues/events API (the event actor is `repairman29` — the repo owner via the API token, not a dedicated bot).

## Did INFRA-1219 (dedup gate) fail?

**No — it had no opportunity to fire.** The gate runs at `gh pr create` time. Because #1908 was already closed (branch deleted at 17:31:16Z) before #1921 was created, there was no open duplicate to detect. The dedup gate would have correctly blocked #1921 if #1908 had still been open at that moment.

**Conclusion:** INFRA-1219 is working correctly. The gap was: operator branch-deletion closed #1908 before the new PR was created, so the guard was never invoked.

## Did INFRA-1220 (cooldown) help?

The cooldown logic stamps a gap after its associated PR is closed so a new claim can't happen immediately. However, the reclaim sequence here happened within seconds of the branch deletion. The ambient stream shows no `gap_cooldown_stamp` or `orphan_pr_closed` event — the orphan-pr-closer wasn't the closer, so it never stamped the cooldown. The branch-deletion path bypasses the cooldown stamp. This is a coverage gap.

## Coverage gap found (do not fix here — file follow-up)

The branch-deletion-closes-PR path does not stamp a cooldown. If an operator or bot deletes a PR's head branch (e.g., during `chump claim` cleanup), GitHub closes the PR, but INFRA-1220 never learns about it. A new claim could be created immediately.

**Filed:** INFRA-1305 — stamp cooldown when branch deletion closes a PR (see below).

## Parallel-ship pattern reference (CLAUDE_GOTCHAS addition)

When two agents or sessions race to claim the same gap:

1. **First PR wins the merge** — auto-merge arms and lands via squash. 
2. **Second PR's branch** — if deleted before the new PR is created, GitHub closes it silently. The event shows `actor = repo_owner` (API token), `closed_by = null` — looks like manual close.
3. **Dedup gate (INFRA-1219)** protects against creating a second PR while the first is still open. It does NOT protect against the case where both PRs are created before either merges.
4. **Orphan-pr-closer (INFRA-1139)** catches PRs whose gap is already done. It runs on a schedule, not instantly.
5. **Fastest close path:** delete the head branch → GitHub closes the PR in <1s, no gate sees it.

## Verification checklist (AC)

- [x] AC-1: Inspected `gh api repos/.../issues/1908/events` — actor is `repairman29`, event is `closed` at 17:31:17Z.
- [x] AC-2: Searched `ambient.jsonl` for `orphan_pr_closed`, `pr_dedup_blocked` near 17:31:17Z — none found for #1908.
- [x] AC-3: Documented mechanism: branch deletion, not dedup gate or orphan closer.
- [x] AC-4: Found coverage gap (cooldown not stamped on branch-deletion close) — filed INFRA-1305.
- [x] AC-5: Adding parallel-ship pattern to CLAUDE_GOTCHAS.md (below).
