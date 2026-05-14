🤖 **Queue audit (`chump pr nudge` auto-posted)** — this PR appears **orphan**: auto-merge is disarmed and there's no recent commit activity. If the original agent is no longer driving it, this PR can be safely closed.

PR state: SHA `{{SHA_SHORT}}`, last commit `{{LAST_COMMIT_AGE}}` ago.

If you (the author/maintainer agent) are still working on this:
1. Rebase if needed (`git fetch origin main && git rebase origin/main`)
2. Push (`git push --force-with-lease`)
3. Once required CI green, REST-merge: `gh api -X PUT repos/repairman29/chump/pulls/{{PR}}/merge -f merge_method=squash`

If you've moved on:
- Close the PR. INFRA-1083-family auto-refiling will surface the unmet need if it's still relevant.
- Or arm auto-merge: `gh pr merge {{PR}} --auto --squash` (requires GraphQL — only works when rate limit allows).

Diagnosis: `orphan-disarmed` (auto-merge not armed + no recent activity). See [docs/process/PR_NUDGE.md](../../docs/process/PR_NUDGE.md) for details.
