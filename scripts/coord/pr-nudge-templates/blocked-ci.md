🤖 **Queue audit (`chump pr nudge` auto-posted)** — this PR is `blocked` by failing required CI on SHA `{{SHA_SHORT}}`.

Failing required checks: **{{FAILING_CHECKS}}**.

If you suspect a flake (e.g. `test` rollup failing on `fast-checks` from a parallel-execution race like `waste_tally::tests::infra488_excludes_events_outside_window`):

1. Verify by running the failing test in isolation:
   `cd <worktree> && cargo test --bin chump <failing-test-name>`
2. If it passes alone, add to `docs/process/KNOWN_FLAKES.yaml` with a tracking gap.
3. Retrigger via `gh run rerun <run-id> --failed`.

If the failure is real:

1. Reproduce locally → fix → push.
2. Once CI green: REST-merge `gh api -X PUT repos/repairman29/chump/pulls/{{PR}}/merge -f merge_method=squash`.

Diagnosis: `blocked-ci-required` (failing required check). See [docs/process/PR_NUDGE.md](../../docs/process/PR_NUDGE.md) for details.
