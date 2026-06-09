---
doc_tag: canonical
owner_gap: META-209
last_audited: 2026-06-08
---

# Auto-Admin-Merge Policy (META-209)

Agent-initiated admin-merge of PRs without operator session auth. Gated by quorum-based consensus and policy guardrails.

## Policy trigger

An agent may invoke `gh pr merge --admin --squash` on a pull request **if and only if ALL of the following conditions hold**:

1. **Consensus resolved** — `chump consensus-tally <PR-correlation-id>` returns `PASSED` with quorum ≥ 3
2. **Fix-class allowlist** — PR title prefix matches one of: `fix/`, `docs/`, `chore/`, `hotfix/`, `ci/`, `test/`, `revert/`, `build/`, `style/`, `refactor/`, `perf/`
3. **No DIRTY conflict** — `git merge-base --is-ancestor main <PR-head>` and no merge conflict markers exist in the branch
4. **No T1-T4 trigger in last 30m** — no `kind=operator_escalation_*` or `kind=T[1-4]_trigger_fired` event in `ambient.jsonl` in the last 1800 seconds
5. **No operator HOLD label** — PR does not have the `admin-merge-hold` GitHub label

## Definitions

### Consensus resolved

The `deliberator-opus` role has tallied votes on the PR's proposal (keyed by correlation ID, typically the PR number or an explicit consensus tracking ID). A result is "resolved" when:
- Vote window is closed (24h default, configurable via `CHUMP_CONSENSUS_VOTE_WINDOW_S`)
- Tally shows `kind=consensus_result` with `outcome=PASSED`
- Vote count includes ≥ 3 unique agents (quorum requirement)

Tie-breaking: majority of votes (`votes_for > votes_against + abstentions`).

### Fix-class allowlist

A PR whose title **starts with** one of these prefixes qualifies:

| Class | Scope | Example |
|-------|-------|---------|
| `fix/` | Bug fixes | `fix(INFRA-1234): close gap...` |
| `docs/` | Documentation, READMEs, comments | `docs(ROADMAP): update Q2 milestones` |
| `chore/` | Dependency updates, build config, CI infra | `chore: upgrade serde to 1.0.200` |
| `hotfix/` | Emergency production fixes | `hotfix(INFRA-2999): auth-dead recovery` |
| `ci/` | CI/CD gates, workflow edits, test infra | `ci: add cargo clippy to pre-push hook` |
| `test/` | Test additions, test suite fixes | `test: add regression case for issue #42` |
| `revert/` | Revert a prior commit | `revert: undo PR #2800 (reverted manually at merge time)` |
| `build/` | Build system, Cargo.toml, script tooling | `build: add release profile optimization` |
| `style/` | Formatting, lint, non-logic whitespace | `style: cargo fmt --all` |
| `refactor/` | Code reorganization without behavior change | `refactor: extract gap-validator to own module` |
| `perf/` | Performance improvements | `perf: cache git ls-tree results in bot-merge` |

A PR with title `fix(INFRA-1234): ...` matches; `Fix(INFRA-1234): ...` (capital F) does not. Matching is case-sensitive, prefix-exact.

### No DIRTY conflict

The branch must be mergeable (fast-forward or clean 3-way) with `main`. The agent:
1. Checks that the PR's base and head are both reachable: `git merge-base --is-ancestor main <head_sha>`
2. Attempts a dry-run merge: `git merge-tree main <head_sha>` and validates zero conflict markers in output
3. Confirms no `DIRTY` label on the PR (set manually by human reviewers when merge conflicts exist)

### No T1-T4 trigger in last 30m

Inspect `ambient.jsonl` for entries with `"ts"` within the last 1800 seconds and `"kind"` matching any of:

```
kind=operator_escalation_unjustified
kind=operator_escalation_justified
kind=T1_trigger_fired
kind=T2_trigger_fired
kind=T3_trigger_fired
kind=T4_trigger_fired
```

If **any** such event exists in the last 30 minutes, admin-merge is **blocked**. This ensures the fleet is not in active escalation / operator-intervention mode.

Reference: [META-207 Escalation Doctrine](./NO_ESCALATION_DOCTRINE.md):
- **T1** — Irreversible third-party action (financial, production deploy outside Chump, external partner communication)
- **T2** — Credential rotation requiring operator hands-on-keyboard
- **T3** — Operator-explicit-domain (legal, licensing, partnerships, pricing, branding)
- **T4** — Halt-class fleet condition (trunk-RED AND auth-dead AND queue-starve simultaneously, consensus unsafe to use)

### No operator HOLD label

The agent checks the PR's GitHub labels via `gh pr view <number> --json labels`. If the label set includes `admin-merge-hold`, the merge is **blocked**.

The operator may apply this label to any PR needing human review before admin-merge proceeds, overriding all other conditions.

## Audit

Each agent admin-merge emits to `ambient.jsonl`:

```json
{
  "ts": "2026-06-08T18:45:12Z",
  "kind": "agent_admin_merge",
  "pr_number": 2847,
  "pr_title": "fix(INFRA-2222): close gap",
  "agent_role": "orchestrator",
  "fix_class": "fix",
  "consensus_corr_id": "corr_2847",
  "consensus_vote_count": 4,
  "trigger_check_results": {
    "consensus_resolved": true,
    "fix_class_allowed": true,
    "no_dirty_conflict": true,
    "no_T_trigger_last_30m": true,
    "no_operator_hold": true
  }
}
```

## Failure cases

If **any** condition fails, the agent emits `kind=agent_admin_merge_blocked` with the failing condition in `reason` and **must not invoke** `gh pr merge --admin`.

## Decision history

- **2026-05-30** — Operator directive to codify admin-merge protocol so Chump can autonomously admin-merge consensus-passed PRs without operator session auth
- **2026-06-03** — Consensus layer (deliberator, vote tally) went live; A2A publish bus wired
- **2026-06-08** — Policy document filed as META-210 (slice of META-209)
