# Bot-merge tiered lane observability (INFRA-1767)

`scripts/coord/bot-merge.sh --lane {internal,user-facing,critical}` gates
auto-merge arming behind a merge-risk tier. This doc is the audit reference
for the ambient events the lane machinery emits and the failure-class
taxonomy used to distinguish a permanent design gate from a transient one.

## Lanes

| Lane | Auto-merge default (no `--auto-merge`) | `--auto-merge` passed | chump-policy baseline |
|---|---|---|---|
| `internal` (default) | ON | ON | lowest blast radius (RESILIENT-190) |
| `user-facing` | OFF | ON (subject to policy gate) | requires human review by default |
| `critical` | OFF | still blocked by chump-policy unless the operator explicitly opts a scope in | refuses auto-merge even when `--auto-merge` is passed |

Lane resolution happens in `scripts/coord/bot-merge.sh` before any push;
the enforcement gate itself lives in `crates/chump-policy` (`chump-policy
check --lane <lane>`), invoked around the auto-merge-arm step.

## Events

All events land in `.chump-locks/ambient.jsonl`.

### `kind=bot_merge_lane_resolved`

Emitted once per `bot-merge.sh` invocation, immediately after flag parsing,
regardless of whether the policy check later blocks. Records what lane was
resolved and whether auto-merge was requested/explicit.

```json
{"ts":"...", "kind":"bot_merge_lane_resolved", "lane":"internal",
 "auto_merge_requested":true, "auto_merge_explicit":false, "session":"..."}
```

Source: `scripts/coord/bot-merge.sh` (search `bot_merge_lane_resolved`).

### `kind=auto_merge_policy_evaluated`

Emitted by `chump-policy check --lane <lane>` (via
`crates/chump-policy/src/bin/chump-policy.rs`) on the **allowed** branch,
right before `bot-merge.sh` arms auto-merge. Forwarded verbatim from the
binary's stdout into `ambient.jsonl` by the caller.

```json
{"ts":"...", "kind":"auto_merge_policy_evaluated", "lane":"internal", "outcome":"allowed"}
```

### `kind=auto_merge_policy_blocked`

Emitted by the same `chump-policy check` invocation on the **blocked**
branch. Carries `failure_class` (see taxonomy below), the human-readable
`reason`, and the list of `contributing` scopes (`fleet`, `operator`,
`repo`, `lane`) that caused the block — precedence order is
fleet → operator → repo → lane, most-restrictive wins.

```json
{"ts":"...", "kind":"auto_merge_policy_blocked", "lane":"critical",
 "failure_class":"permanent_by_design",
 "reason":"...", "contributing":["lane"]}
```

`bot-merge.sh` also posts the block reason as a PR comment
(`🤖 INFRA-2155: auto-merge NOT armed. Reason: ...`) so the operator sees
the WHY without grep-archaeology.

### `kind=auto_merge_policy_bypassed`

Emitted by `bot-merge.sh` when `CHUMP_BYPASS_AUTO_MERGE_POLICY=1` skips the
`chump-policy check` call entirely. This is the audit trail for the escape
hatch — every bypass is logged even though the gate itself never ran.

```json
{"ts":"...", "kind":"auto_merge_policy_bypassed", "pr":1234, "session":"..."}
```

## Failure-class taxonomy

`chump-policy check` classifies every block into exactly one of two
classes (`crates/chump-policy/src/bin/chump-policy.rs::cmd_check`):

- **`permanent_by_design`** — the block's `contributing` scopes are
  `["lane"]` *and* the lane is `critical`. This is not a review or trust
  gate that clears over time; the critical-lane baseline
  (`Lane::Critical::default_policy`) is designed to refuse auto-merge
  unconditionally, and no other scope (fleet/operator/repo) can override
  it permissive — most-restrictive always wins for critical. The only way
  past this class is an explicit operator opt-in (see Escape hatches
  below), not waiting.
- **`transient_review_or_trust_gate`** — every other block: fleet-level
  disable, operator `--require-human-review`, repo-level disable, or a
  trust-threshold not yet met (`reviewed_pr_count < threshold`) on the
  `internal`/`user-facing` lanes. These clear on their own as review count
  accrues or an operator/repo policy flips — no code change required.

The distinction matters operationally: a `transient_review_or_trust_gate`
block is a "wait or accrue trust" situation; a `permanent_by_design` block
on the critical lane means "this PR needs a human decision, full stop."

## Cost tracking

N/A. `chump-policy check` is a local, synchronous, file-backed check
(reads `.chump/policy-*.json` scope files + the in-memory lane baseline).
No LLM or external API call is made, so there is no cost to track for this
gate.

## Escape hatches (auditable)

- `CHUMP_BYPASS_AUTO_MERGE_POLICY=1` — skip the `chump-policy check` call
  entirely. Emits `kind=auto_merge_policy_bypassed`.
- `chump-policy set --scope <fleet|operator|repo> ...` — durably change a
  scope's policy (e.g. lower `--require-human-review` or bump
  `reviewed_pr_count` via `chump-policy record-review`). Does not apply to
  `Scope::Lane`, which has no on-disk file — the lane baseline is fixed by
  `Lane::default_policy()` and can only be changed by choosing a different
  `--lane`.

## Smoke test

`bash scripts/ci/test-auto-merge-policy.sh` — Tests 8a-8e cover the lane
tier specifically:

- 8a: `--lane internal` allows by default
- 8b: `--lane user-facing` blocks by default (requires human review)
- 8c: `--lane critical` blocks even with fully permissive other scopes
      (`permanent_by_design`)
- 8d: invalid `--lane` value errors rather than silently defaulting
      permissive
- 8e: `chump-policy show --lane critical` reports lane + blocked state in
      JSON
