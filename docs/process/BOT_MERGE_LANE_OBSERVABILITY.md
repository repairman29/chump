---
doc_tag: canonical
owner_gap: INFRA-1767
last_audited: 2026-07-23
---

# Bot-merge tiered lane policy — observability (INFRA-1767)

The tiered merge-lane feature (internal / user-facing / critical, `--lane` flag
on `scripts/coord/bot-merge.sh`, gated by `crates/chump-policy`) shipped in
PR #3273. This doc answers the four observability questions every gap in this
class is graded on — it's documentation of what already ships, not new code.

## 1. Events emitted on success/failure/timeout

There is no separate "timeout" state for a lane decision — it's a synchronous
CLI check, not a long-running operation. The two states are allow/block:

| Event kind | Emitter | When |
|---|---|---|
| `bot_merge_lane_resolved` | `scripts/coord/bot-merge.sh` | Once per run, immediately after CLI flag parsing — discloses which lane (`internal`/`user-facing`/`critical`) was resolved and whether auto-merge was requested implicitly (lane default) or explicitly (`--auto-merge`). |
| `auto_merge_policy_evaluated` | `crates/chump-policy/src/bin/chump-policy.rs` | `chump-policy check --lane <lane>` allows auto-merge under the current layered policy (fleet/operator/repo/lane, most-restrictive wins). |
| `auto_merge_policy_blocked` | `crates/chump-policy/src/bin/chump-policy.rs` | The policy chain blocks auto-merge. Carries `lane`, `contributing` scopes, and `failure_class` (see taxonomy below). |
| `auto_merge_policy_bypassed` | `scripts/coord/bot-merge.sh` | `CHUMP_BYPASS_AUTO_MERGE_POLICY=1` skips the check entirely — always audited, never silent. |

Full field-level contracts: `docs/observability/EVENT_REGISTRY.yaml` (search
`bot_merge_lane_resolved` / `auto_merge_policy_*`).

## 2. Cost tracking

This feature has **no incremental cost to track**. `chump-policy check` is a
local, synchronous Rust binary invocation reading `Policy` state off disk
(`crates/chump-policy/src/lib.rs`) — it makes no LLM calls, no GitHub API
calls, and no network requests. There is nothing here that consumes
`ANTHROPIC_API_KEY` budget or GH rate-limit budget, so no cost-leaderboard
hook is needed for this gap.

## 3. Failure-class taxonomy (transient vs. permanent)

`auto_merge_policy_blocked` carries a `failure_class` field distinguishing:

- **`permanent_by_design`** — the `critical` lane blocked the merge. This is
  not a transient gate that clears with more reviews or time; `critical` is
  disabled by default and stays blocked until an operator explicitly enables
  it per-repo/operator (`crates/chump-policy/src/bin/chump-policy.rs:313-317`).
- **`transient_review_or_trust_gate`** — a review-count or trust-threshold
  gate (e.g. `require_human_review`, `reviewed_pr_count` below the operator's
  trust cliff) that clears on its own once the condition is satisfied (a
  human reviews the PR, or the trust counter increments).

The distinction matters operationally: a `permanent_by_design` block should
never be retried in a loop (it needs an explicit policy change), while a
`transient_review_or_trust_gate` block is expected to resolve without
intervention.

## 4. Smoke test command

```bash
bash scripts/ci/test-auto-merge-policy.sh
```

Test 8 (`8a`-`8e`) in that suite exercises the lane feature specifically:
default-allow on `internal`, default-block on `user-facing` and `critical`
(with `failure_class` asserted), rejection of an invalid `--lane` value, and
`chump-policy show --lane critical --json` reporting the lane in its output.
CI-gate integration (`EVENT_REGISTRY.yaml` presence, bypass event) is covered
by `scripts/ci/test-bot-merge-policy-integration.sh`.
