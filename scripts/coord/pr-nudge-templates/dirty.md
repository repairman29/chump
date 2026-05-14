🤖 **Queue audit (`chump pr nudge` auto-posted)** — this PR is `dirty` against current `main` (base moved). Required CI on the current SHA (`{{SHA_SHORT}}`) is **{{REQUIRED_STATUS}}**.

To land:
1. `git fetch origin main`
2. `git rebase origin/main` — most conflicts in this batch are mechanical (`Cargo.lock`, `docs/observability/EVENT_REGISTRY.yaml`, `docs/gaps/*.yaml` status flips)
3. `git push --force-with-lease`
4. Once CI re-runs green: `gh api -X PUT repos/repairman29/chump/pulls/{{PR}}/merge -f merge_method=squash`
   (`bot-merge.sh --auto-merge` is in rate-limit backoff loop right now; REST direct-merge works.)

If the original agent is no longer active, this PR can be closed — INFRA-1083-family auto-refiling will pick it up.

Diagnosis: `dirty` (mergeable=true, mergeable_state=dirty). See [docs/process/PR_NUDGE.md](../../docs/process/PR_NUDGE.md) for details.
