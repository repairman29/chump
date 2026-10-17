---
doc_tag: runbook
owner_gap: CREDIBLE-1510
last_audited: 2026-10-17
---

# Merge queue flip (operator runbook, CREDIBLE-1510)

Turns on a GitHub merge queue for `main` so CI runs once per batch on the
`merge_group` ref instead of once per PR after every landing. Why and the
before-measurement: `docs/strategy/PHASE_R_ARCHITECTURE_PROGRAM_2026-10-15.md`,
section "R3 throughput". Repo-side readiness landed with CREDIBLE-1510; this is
the one step only the operator takes.

## Read first: the ownership blocker

`repairman29/chump` is owned by a personal account. `MERGE_QUEUE_SETUP.md`
records `422 Validation Failed: Invalid rule 'merge_queue'` from the rulesets API
on 2026-04-19, re-confirmed unavailable 2026-08-22. Not re-tested since (a test
is itself a settings write). If step 1 returns that 422, stop: nothing is
changed, and R3 throughput needs an owner decision (move the repo under an
organization, or a different landing model). Do not retry with variations.

## Before

```bash
bash scripts/ci/test-merge-group-coverage.sh   # verified -> ci.yml, merge_group-wired
bash scripts/ci/test-branch-protection-gate.sh # payload shape + classic baseline
```

## 1. Flip

The body is checked in and shape-gated: `docs/baselines/ruleset-main-merge-queue.json`.

```bash
gh api -X POST repos/repairman29/chump/rulesets --input docs/baselines/ruleset-main-merge-queue.json
```

Same body inline:

```json
{
  "name": "main merge queue",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN",
        "max_entries_to_build": 5,
        "min_entries_to_merge": 1,
        "max_entries_to_merge": 5,
        "min_entries_to_merge_wait_minutes": 2 } },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "verified", "integration_id": 15368 } ] } }
  ]
}
```

Field notes. All seven `merge_queue` parameters are required by the REST
schema (checked against the "Create a repository ruleset" docs 2026-10-17);
value ranges were not stated there. `integration_id` 15368 is GitHub Actions,
copied from the live "Protect main" ruleset (id 15133729), which already
requires `verified` with `strict` off. Rules from all rulesets stack, so the
`required_status_checks` rule here mainly adds the strict policy; drop it if
GitHub refuses the pair. No `bypass_actors`: admins queue too, which matches
classic `enforce_admins=true`.

## 2. Verify

```bash
gh api repos/repairman29/chump/rules/branches/main --jq '[.[].type]'   # must contain "merge_queue"
```

The first armed PR that goes green should show `isInMergeQueue: true`
(`gh api graphql -f query='{repository(owner:"repairman29",name:"chump"){mergeQueue(branch:"main"){entries(first:10){nodes{pullRequest{number}}}}}}'`)
and a `ci.yml` run with event `merge_group`.

## 3. Revert

```bash
gh api -X DELETE repos/repairman29/chump/rulesets/$(gh api repos/repairman29/chump/rulesets --jq '.[] | select(.name=="main merge queue") | .id')
```

Classic branch protection is untouched by the flip and by the revert.

## What the fleet does once the queue exists

- Armers keep calling `gh pr merge --auto --squash`; with a queue that enqueues.
- Rebasers (`lib/pr_rebase.sh` callers: pr-shepherd-daemon, cascade-unblock-detector,
  wizard-daemon, pr-failure-auto-rescue; plus `armed-pr-rebaser.sh`) skip any PR
  already in the queue, because an outside update-branch or force-push evicts it.
  A failed queue lookup skips the mutation for that cycle.
- PRs that are BEHIND but not queued are still rebased while classic `strict=true`
  stands. Whether GitHub then still demands up-to-date branches before enqueueing
  is unverified; if PRs enqueue while BEHIND, those rebases are wasted CI and
  classic `strict` can go off (update `docs/baselines/branch-protection-main.json`
  in the same change).
- Fill in "Measured after" under R3 in the Phase R doc.
