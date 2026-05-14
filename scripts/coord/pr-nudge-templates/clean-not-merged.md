🤖 **Queue audit (`chump pr nudge` auto-posted)** — this PR is `clean` (all required CI green, no conflicts) but hasn't been merged. Either auto-merge wasn't armed, or it was armed and got disarmed.

If you're ready to land this:
```
gh api -X PUT repos/repairman29/chump/pulls/{{PR}}/merge -f merge_method=squash
```

Or rearm auto-merge (requires GraphQL headroom):
```
gh pr merge {{PR}} --auto --squash
```

Diagnosis: `clean-not-merged` (all green, no auto-merge active). See [docs/process/PR_NUDGE.md](../../docs/process/PR_NUDGE.md) for details.
