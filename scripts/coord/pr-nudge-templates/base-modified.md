🤖 **Queue audit (`chump pr nudge` auto-posted)** — all required CI checks on SHA `{{SHA_SHORT}}` are **green**, but the PR is currently `blocked` because the base branch (`main`) moved between your last push and now.

Retry the merge:
```
gh api -X PUT repos/repairman29/chump/pulls/{{PR}}/merge -f merge_method=squash
```

GitHub's mergeable_state can lag the actual state by 1-2 minutes after a base merge; if the retry says "Pull Request is not mergeable", wait 60s and try again.

If you want auto-merge instead (so it picks up on the next CI run), and GraphQL has headroom:
```
gh pr merge {{PR}} --auto --squash
```

Diagnosis: `base-modified` (all required green, blocked on stale base). See [docs/process/PR_NUDGE.md](../../docs/process/PR_NUDGE.md) for details.
