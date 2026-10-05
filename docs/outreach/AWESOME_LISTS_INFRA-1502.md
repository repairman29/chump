# Awesome-list placement — INFRA-1502 disposition

Chump (`repairman29/chump`) has 1 GitHub star as of 2026-08-21. That fact drove the
outcome for each target list.

## Opened

- **kailiu42/awesome-coding-agents** — [PR #28](https://github.com/kailiu42/awesome-coding-agents/pull/28).
  Actively maintained (merged PRs same-day), single curator, no numeric star bar —
  entries are accepted on fit/tags, not popularity. Added Chump under
  "CLI Agent Helpers" per the repo's own `add-tool` skill contract (status `👀`,
  GitHub-About description, no marketing copy, no generated metrics in the row).

## Skipped — documented, not opened

- **awesome-rust** (`rust-unofficial/awesome-rust`) — `CONTRIBUTING.md` sets a hard,
  mechanically-checked bar: `stars > 50 | downloads > 2000`. Chump has 1 star and no
  crates.io downloads. Opening a PR here today would fail the stated bar outright —
  wasted maintainer review cycles for a submission that reads as vanity/spam against
  the list's own stated norms. **Follow-up:** revisit once Chump crosses 50 stars,
  or cites an equivalent popularity metric per the CONTRIBUTING template.
- **awesome-llm-agents** (`kaushikb11/awesome-llm-agents`) — most active, best-fit
  "awesome-llm-agents"-named list (weekly-refreshed metrics, per-entry YAML files,
  CI-checked). `CONTRIBUTING.md` requirement #4: "At least 25 stars, or published by
  a recognized organization or research lab." Chump meets neither. Same reasoning as
  above — skip rather than submit a submission guaranteed to fail an explicit,
  automated bar. **Follow-up:** revisit once Chump crosses 25 stars.

## Maintainer outreach

No "open an issue first" CONTRIBUTING language on any of the three lists — all
three accept PRs directly, so no separate issue-based outreach was needed. The one
PR opened (awesome-coding-agents #28) is the full extent of outbound contact for
this gap; track it in the operator-tracker for a 2-week no-response follow-up per
the gap's AC. Operator-facing outreach/legal/commercial decisions (if any arise from
maintainer replies) belong in `chump-proprietary/OPERATOR_ACTIONS.md`, not this repo.

## Follow-up

If PR #28 sits open >2 weeks without a maintainer response, or once Chump's star
count clears the awesome-rust/awesome-llm-agents thresholds, file a fresh gap to
revisit — don't reopen INFRA-1502.
