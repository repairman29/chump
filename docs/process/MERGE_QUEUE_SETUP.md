---
doc_tag: runbook
owner_gap: INFRA-201
last_audited: 2026-05-01
---

# GitHub merge queue — setup guide (INFRA-MERGE-QUEUE → superseded by INFRA-201)

**Status as of 2026-05-01:** **No real merge queue exists on this repo.** The
feature is an org Team / Enterprise paid plan capability and is not exposed on
personal-account public repos like `repairman29/chump`. Three independent
attempts to enable it via REST/GraphQL all failed (see [API attempts](#api-attempts-failed)
below). The 2026-04-19 doc was aspirational.

**What we actually have (INFRA-201, 2026-05-01):** the `strict` (require-up-to-date-branches)
flag is **disabled** on the legacy branch protection rule for `main`. Every PR
auto-merges as soon as its **own** required checks (`test`, `audit`, `ACP smoke
test`) are green, regardless of how many commits `main` has advanced
underneath it. This eliminates the BEHIND-cascade traffic jam we used to hit
when 5–10 PRs auto-armed in parallel — only one could land per CI cycle, the
rest went BEHIND, someone had to `gh pr update-branch` them sequentially. Now
they all land independently.

**What this trades off:** without `strict`, a PR can land that was tested
against an older `main`. Two PRs touching the same file with non-overlapping
edits will textually merge cleanly; two PRs touching the same lines go DIRTY
and need a hand rebase (visible immediately in the PR list, no surprise).
Logical conflicts (same gap-ID added twice; redundant doc edits; etc.) are
caught by the pre-commit guards and `gap-doctor.py`. This is the correct
tradeoff for a single-maintainer fast-moving repo.

**Squash-loss footgun (PR #52)** is still mitigated by atomic-PR discipline
and the `pr-<N>-checkpoint` tag `bot-merge.sh` writes — see CLAUDE.md
"Auto-merge IS the default" note.

## Branch-protection drift detector (INFRA-121, 2026-05-01)

The single-PR auto-merge path described above is load-bearing — and silently
breaks if the branch-protection rule on `main` drifts (a required check is
renamed, a context is added/removed, the rule is altered or disabled in
Settings). Symptom seen previously: `bot-merge.sh --auto-merge` arms a PR,
CI passes, but the PR sits OPEN forever because GitHub no longer recognises
the green checks as "all required". The CLAUDE.md "If the merge queue is
stuck" recovery section documents how to dig out — INFRA-121 prevents the
state from happening unnoticed in the first place.

- **Baseline:** [`docs/baselines/branch-protection-main.json`](../baselines/branch-protection-main.json) —
  normalized snapshot of the live `main` protection rule (URLs stripped, keys
  sorted) so a git diff is purely semantic. Refresh after any *intentional*
  change with `scripts/ops/branch-protection-drift.sh --update-baseline` and
  commit the new baseline.
- **Detector:** [`scripts/ops/branch-protection-drift.sh`](../../scripts/ops/branch-protection-drift.sh) —
  fetches live config via `gh api`, normalizes, diffs against the baseline.
  Quiet on match (single `ok` row in `.chump/health.jsonl`); on drift writes
  ALERT `kind=queue_config_drift` to `ambient.jsonl` + `.chump/alerts.log`
  with the field-level diff. Sibling agents see the alert in their
  FLEET-019 `SessionStart` digest.
- **CI job:** [`.github/workflows/branch-protection-drift.yml`](../../.github/workflows/branch-protection-drift.yml)
  runs daily (07:23 UTC) and on every push to the baseline / detector / workflow
  itself. A non-zero diff fails the job — the failure notification is the
  remote alert channel.
- **Local hourly run (macOS):** `scripts/setup/install-branch-protection-drift-launchd.sh`
  installs a daily LaunchAgent so an operator's machine ALERTs to ambient.jsonl
  without waiting on CI cadence. Verify with `launchctl list | grep
  ai.openclaw.chump-branch-protection-drift`.

---

## Original 2026-04-19 framing (kept for context)

---

## Why we use a merge queue

The Chump repo runs many parallel agent worktrees. Without a merge queue the
ship-pipeline pattern breaks down in two ways:

1. **Squash-merge loss** — GitHub captures the branch state at the moment CI
   first goes green, then drops every commit pushed afterward. PR #52 lost 11
   commits this way on 2026-04-18; recovery PR #65 had to be hand-cherry-picked.
2. **BEHIND surprises** — when two PRs that both pass CI against the same base
   sha land back-to-back, the second silently merges stale code. This was the
   reason for the long-standing rule "rebase before merging" and for many
   `fix(ci): rebase on main` commits.

A merge queue solves both: every PR is rebased onto the *current* `main`,
re-runs CI, and merges atomically. Auto-merge becomes safe-by-default.

---

## API attempts (failed)

Attempted with admin token on 2026-04-19. Recorded so the next agent doesn't
have to re-discover them.

### 1. Branch protection PUT with `required_merge_queue`

```bash
gh api -X PUT repos/repairman29/chump/branches/main/protection \
  --input branch-prot.json   # contains "required_merge_queue": {...}
```

Result: HTTP 200, but the response body omits `required_merge_queue` and a
follow-up GET shows the field absent. Silently ignored.

### 2. Rulesets PATCH adding a `merge_queue` rule

```bash
gh api -X PUT repos/repairman29/chump/rulesets/15133729 \
  --input ruleset-update.json   # adds {"type": "merge_queue", ...}
```

Result: `422 Validation Failed — Invalid rule 'merge_queue'`. The rule type
exists in newer Enterprise versions but is not exposed on `repairman29/chump`
via the REST API surface as of 2026-04-19.

### 3. GraphQL `mergeQueue` query (read-only check)

```bash
gh api graphql -f query='query { repository(owner:"repairman29", name:"chump") { mergeQueue(branch:"main") { url } } }'
# → {"data":{"repository":{"mergeQueue":null}}}
```

Returns `null` — confirms not yet enabled. GraphQL does not expose a mutation
to create one.

---

## GitHub UI fallback (REQUIRED — human, repo admin)

1. Open https://github.com/repairman29/chump/settings/branches
2. Under **Branch protection rules**, click the existing rule for `main` (or
   the ruleset "Protect main" at https://github.com/repairman29/chump/rules ).
3. Toggle **Require merge queue** ON.
4. Configure the queue:
   - **Merge method:** Squash and merge (matches `bot-merge.sh --auto --squash`).
   - **Build concurrency (max parallel checks):** 1 — Chump's CI is sized for one
     PR-at-a-time and parallel queue builds will starve runners.
   - **Minimum entries to merge:** 1 (don't batch — agents expect single-PR landings).
   - **Maximum entries to merge:** 5 (batches up to 5 if they all green-light together).
   - **Wait for entries to merge:** 5 minutes.
   - **Grouping strategy:** ALLGREEN — fail the whole batch if any one fails CI.
   - **Status check timeout:** 60 minutes (covers the slow `tauri-cowork-e2e` job).
5. Save.
6. Verify (see below).

---

## Verification

```bash
# 1. GraphQL: queue should now return a non-null URL.
gh api graphql -f query='query { repository(owner:"repairman29", name:"chump") {
  mergeQueue(branch:"main") { url entries(first:5) { totalCount } } } }'

# Expected:
# {"data":{"repository":{"mergeQueue":{"url":"https://github.com/repairman29/chump/queue/main","entries":{"totalCount":0}}}}}

# 2. Open two PRs from sibling worktrees with bot-merge.sh.
#    Both will arm `gh pr merge --auto --squash`. Watch the queue serialize them:
open https://github.com/repairman29/chump/queue/main
```

When working: each PR enters the queue, GitHub creates a temporary merge
branch (rebased on the current main + pending queue tip), CI runs against
that temporary branch, and on success the PR squash-merges atomically. No
"BEHIND" surprises, no commits pushed-after-CI lost.

---

## What this changes for agents

- `bot-merge.sh --auto-merge` is now the **default ship pattern**, not the
  scary one. The queue protects against squash-loss.
- See `docs/process/AGENT_COORDINATION.md` § "Auto-merge with merge queue".
- See `CLAUDE.md` for the updated hard rules.

---

## Deferred follow-ups

- **CODEOWNERS** — not configured. Required reviewers are zero. If we ever
  want gated reviews, file a follow-up gap and add a `.github/CODEOWNERS`.
- **Required status check rename** — the queue currently inherits the same
  three required checks (`test`, `audit`, `tauri-cowork-e2e`). If any check
  is renamed, update both the branch protection rule AND the queue config.
- **Per-PR fast-forward path for trivial docs** — not implemented. Every PR
  goes through the queue today. Cheap, but adds ~CI-runtime latency to a
  doc-only change.
